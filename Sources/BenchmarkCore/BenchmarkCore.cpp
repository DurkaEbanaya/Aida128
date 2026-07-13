#include "BenchmarkCore.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits>
#include <mutex>
#include <new>
#include <numeric>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/sysctl.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

#if defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace {

constexpr uint64_t kNanosecondsPerSecond = 1'000'000'000ULL;
constexpr size_t kAlignment = 64;
constexpr size_t kKernelQuantum = 256;
volatile uint64_t g_observable_sink = 0;
std::atomic_flag g_benchmark_running = ATOMIC_FLAG_INIT;

class BenchmarkRunLease {
public:
    BenchmarkRunLease() noexcept
        : acquired_(!g_benchmark_running.test_and_set(std::memory_order_acquire)) {}

    ~BenchmarkRunLease() {
        if (acquired_) g_benchmark_running.clear(std::memory_order_release);
    }

    explicit operator bool() const noexcept { return acquired_; }

    BenchmarkRunLease(const BenchmarkRunLease &) = delete;
    BenchmarkRunLease &operator=(const BenchmarkRunLease &) = delete;

private:
    bool acquired_;
};

bool read_sysctl(const char *name, void *value, size_t *size) {
    return sysctlbyname(name, value, size, nullptr, 0) == 0;
}

uint64_t read_uint64_sysctl(const char *name) {
    uint64_t value = 0;
    size_t size = sizeof(value);
    return read_sysctl(name, &value, &size) ? value : 0;
}

std::string read_string_sysctl(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || size == 0) {
        return {};
    }
    std::string value(size, '\0');
    if (!read_sysctl(name, value.data(), &size)) {
        return {};
    }
    value.resize(std::strlen(value.c_str()));
    return value;
}

void copy_string(char *destination, size_t capacity, const std::string &source) {
    if (capacity == 0) return;
    std::snprintf(destination, capacity, "%s", source.c_str());
}

std::string first_registry_string(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return {};
    std::string result;
    auto copy_cf_string = [&result](CFStringRef string) {
        const CFIndex length = CFStringGetLength(string);
        const CFIndex capacity = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
        std::vector<char> buffer(static_cast<size_t>(capacity));
        if (CFStringGetCString(string, buffer.data(), capacity, kCFStringEncodingUTF8)) {
            result = buffer.data();
        }
    };
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        copy_cf_string(static_cast<CFStringRef>(value));
    } else if (CFGetTypeID(value) == CFArrayGetTypeID() && CFArrayGetCount(static_cast<CFArrayRef>(value)) > 0) {
        const CFTypeRef first = CFArrayGetValueAtIndex(static_cast<CFArrayRef>(value), 0);
        if (first && CFGetTypeID(first) == CFStringGetTypeID()) copy_cf_string(static_cast<CFStringRef>(first));
    } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
        const CFDataRef data = static_cast<CFDataRef>(value);
        result.assign(reinterpret_cast<const char *>(CFDataGetBytePtr(data)), static_cast<size_t>(CFDataGetLength(data)));
        while (!result.empty() && result.back() == '\0') result.pop_back();
    }
    CFRelease(value);
    return result;
}

uint32_t registry_array_count(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return 0;
    uint32_t count = 0;
    if (CFGetTypeID(value) == CFArrayGetTypeID()) {
        count = static_cast<uint32_t>(CFArrayGetCount(static_cast<CFArrayRef>(value)));
    } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
        const CFDataRef data = static_cast<CFDataRef>(value);
        const uint8_t *bytes = CFDataGetBytePtr(data);
        const size_t length = static_cast<size_t>(CFDataGetLength(data));
        bool inside_string = false;
        for (size_t index = 0; index < length; ++index) {
            if (bytes[index] != 0 && !inside_string) {
                ++count;
                inside_string = true;
            } else if (bytes[index] == 0) {
                inside_string = false;
            }
        }
    }
    CFRelease(value);
    return count;
}

uint32_t registry_uint32(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return 0;
    uint32_t result = 0;
    if (CFGetTypeID(value) == CFDataGetTypeID()) {
        const CFDataRef data = static_cast<CFDataRef>(value);
        if (CFDataGetLength(data) >= static_cast<CFIndex>(sizeof(result))) {
            std::memcpy(&result, CFDataGetBytePtr(data), sizeof(result));
        }
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt32Type, &result);
    }
    CFRelease(value);
    return result;
}

io_registry_entry_t device_tree_entry(const char *path) {
    return IORegistryEntryFromPath(kIOMainPortDefault, path);
}

std::string normalized_feature_list() {
    std::string result;
    for (const char *key : {"machdep.cpu.features", "machdep.cpu.leaf7_features", "machdep.cpu.extfeatures"}) {
        const std::string value = read_string_sysctl(key);
        if (value.empty()) continue;
        if (!result.empty()) result += ' ';
        result += value;
    }
    return result;
}

struct PlatformDiscovery {
    std::string memory_type;
    std::string memory_manufacturer;
    std::string memory_part_number;
    std::string platform_name;
    std::string manufacturer;
    std::string board_identifier;
    std::string motherboard;
    std::string chipset;
    std::string firmware;
    uint32_t memory_data_rate = 0;
    uint32_t memory_module_count = 0;
};

struct AppleSoCSpecification {
    const char *name;
    const char *identifier;
    const char *process_node;
    const char *instruction_set;
    const char *memory_technology;
    uint32_t performance_max_megahertz;
    uint32_t efficiency_max_megahertz;
    uint32_t neural_engine_cores;
    uint32_t memory_bandwidth_gigabytes_per_second;
    uint32_t memory_data_rate_mtps;
    uint64_t system_cache_bytes;
};

constexpr AppleSoCSpecification kAppleM5Specification{
    "Apple M5", "T8142", "TSMC N3P (3 nm)", "ARMv9.2-A (AArch64)",
    "LPDDR5X unified memory", 4608, 3048, 16, 153, 9600,
    32ULL * 1024 * 1024
};

const AppleSoCSpecification *apple_soc_specification(const std::string &cpu_name) {
    return cpu_name == kAppleM5Specification.name ? &kAppleM5Specification : nullptr;
}

void store_provenance(
    A128Provenance &output,
    A128ProvenanceKind kind,
    const char *source,
    const char *detail
) {
    output.kind = kind;
    copy_string(output.source, sizeof(output.source), source);
    copy_string(output.detail, sizeof(output.detail), detail);
}

PlatformDiscovery discover_platform() {
    PlatformDiscovery result;
    io_registry_entry_t root = device_tree_entry("IODeviceTree:/");
    if (root) {
        result.platform_name = first_registry_string(root, CFSTR("product-name"));
        const std::string manufacturer = first_registry_string(root, CFSTR("manufacturer"));
        const std::string board_id = first_registry_string(root, CFSTR("board-id"));
        result.manufacturer = manufacturer;
        result.board_identifier = board_id;
        if (!manufacturer.empty() || !board_id.empty()) {
            result.motherboard = manufacturer + (manufacturer.empty() || board_id.empty() ? "" : " / ") + board_id;
        }
        IOObjectRelease(root);
    }

    io_registry_entry_t memory = device_tree_entry("IODeviceTree:/memory");
    if (memory) {
        result.memory_type = first_registry_string(memory, CFSTR("dimm-types"));
        result.memory_manufacturer = first_registry_string(memory, CFSTR("dimm-manufacturer"));
        result.memory_part_number = first_registry_string(memory, CFSTR("dimm-part-number"));
        const std::string speed = first_registry_string(memory, CFSTR("dimm-speeds"));
        if (!speed.empty()) result.memory_data_rate = static_cast<uint32_t>(std::strtoul(speed.c_str(), nullptr, 10));
        result.memory_module_count = registry_array_count(memory, CFSTR("dimm-types"));
        IOObjectRelease(memory);
    }

    io_registry_entry_t rom = device_tree_entry("IODeviceTree:/rom");
    if (!rom) rom = device_tree_entry("IODeviceTree:/rom@0");
    if (rom) {
        const std::string vendor = first_registry_string(rom, CFSTR("vendor"));
        const std::string version = first_registry_string(rom, CFSTR("version"));
        if (vendor == "Acidanthera" || version.rfind("9999.", 0) == 0) {
            result.firmware = "Synthetic SMBIOS firmware (OpenCore/Acidanthera)";
        } else {
            result.firmware = vendor + (vendor.empty() || version.empty() ? "" : " ") + version;
        }
        IOObjectRelease(rom);
    }

    io_iterator_t devices = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPCIDevice"), &devices) == KERN_SUCCESS) {
        uint32_t host_vendor = 0, host_device = 0, subsystem_vendor = 0, subsystem_device = 0;
        uint32_t lpc_vendor = 0, lpc_device = 0;
        while (io_registry_entry_t device = IOIteratorNext(devices)) {
            const uint32_t class_code = registry_uint32(device, CFSTR("class-code")) & 0x00ffffff;
            const uint32_t vendor = registry_uint32(device, CFSTR("vendor-id")) & 0xffff;
            const uint32_t device_id = registry_uint32(device, CFSTR("device-id")) & 0xffff;
            if (class_code == 0x060000 && host_vendor == 0) {
                host_vendor = vendor;
                host_device = device_id;
                subsystem_vendor = registry_uint32(device, CFSTR("subsystem-vendor-id")) & 0xffff;
                subsystem_device = registry_uint32(device, CFSTR("subsystem-id")) & 0xffff;
            } else if (class_code == 0x060100 && lpc_vendor == 0) {
                lpc_vendor = vendor;
                lpc_device = device_id;
            }
            IOObjectRelease(device);
        }
        IOObjectRelease(devices);
        char chipset[96]{};
        std::snprintf(
            chipset, sizeof(chipset), "Host %04X:%04X / LPC %04X:%04X",
            host_vendor, host_device, lpc_vendor, lpc_device
        );
        result.chipset = chipset;
        if (result.motherboard.rfind("Acidanthera", 0) == 0 && subsystem_vendor != 0) {
            char board[128]{};
            const char *vendor_name = subsystem_vendor == 0x1462 ? "MSI" : "PCI subsystem";
            std::snprintf(
                board, sizeof(board), "%s %04X:%04X (exact model masked by SMBIOS)",
                vendor_name, subsystem_vendor, subsystem_device
            );
            result.motherboard = board;
        }
    }
    return result;
}

#if defined(__x86_64__)
struct RawCPUIdentity {
    uint32_t family = 0;
    uint32_t model = 0;
    uint32_t stepping = 0;
    uint32_t signature = 0;
    uint32_t base_megahertz = 0;
    uint32_t max_megahertz = 0;
    uint32_t reference_megahertz = 0;
};

RawCPUIdentity raw_cpu_identity() {
    RawCPUIdentity result;
    unsigned eax = 0, ebx = 0, ecx = 0, edx = 0;
    __cpuid_count(1, 0, eax, ebx, ecx, edx);
    result.signature = eax;
    result.stepping = eax & 0xf;
    const uint32_t base_family = (eax >> 8) & 0xf;
    const uint32_t base_model = (eax >> 4) & 0xf;
    const uint32_t extended_family = (eax >> 20) & 0xff;
    const uint32_t extended_model = (eax >> 16) & 0xf;
    result.family = base_family == 0xf ? base_family + extended_family : base_family;
    result.model = (base_family == 0x6 || base_family == 0xf)
        ? base_model + (extended_model << 4) : base_model;
    if (__get_cpuid_max(0, nullptr) >= 0x16) {
        __cpuid_count(0x16, 0, eax, ebx, ecx, edx);
        result.base_megahertz = eax;
        result.max_megahertz = ebx;
        result.reference_megahertz = ecx;
    }
    const uint64_t package_max_ratio = read_uint64_sysctl("machdep.xcpm.hard_plimit_max_100mhz_ratio");
    if (package_max_ratio > 0 && result.reference_megahertz > 0) {
        result.max_megahertz = std::max<uint32_t>(
            result.max_megahertz,
            static_cast<uint32_t>(package_max_ratio * result.reference_megahertz)
        );
    }
    return result;
}
#endif

uint64_t now_ticks() { return mach_absolute_time(); }

double elapsed_nanoseconds(uint64_t start, uint64_t end) {
    static const mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t value{};
        mach_timebase_info(&value);
        return value;
    }();
    return static_cast<double>(end - start) * static_cast<double>(timebase.numer) /
           static_cast<double>(timebase.denom);
}

struct AlignedBuffer {
    uint8_t *data = nullptr;
    size_t size = 0;

    explicit AlignedBuffer(size_t requested_size) : size(requested_size) {
        if (posix_memalign(reinterpret_cast<void **>(&data), kAlignment, size) != 0) data = nullptr;
    }
    ~AlignedBuffer() { std::free(data); }
    AlignedBuffer(const AlignedBuffer &) = delete;
    AlignedBuffer &operator=(const AlignedBuffer &) = delete;
    AlignedBuffer(AlignedBuffer &&other) noexcept : data(other.data), size(other.size) {
        other.data = nullptr;
        other.size = 0;
    }
    AlignedBuffer &operator=(AlignedBuffer &&other) noexcept {
        if (this == &other) return *this;
        std::free(data);
        data = other.data;
        size = other.size;
        other.data = nullptr;
        other.size = 0;
        return *this;
    }
    explicit operator bool() const { return data != nullptr; }
};

void prefault(uint8_t *data, size_t size) {
    for (size_t offset = 0; offset < size; offset += 4096) data[offset] = static_cast<uint8_t>(offset);
}

#if defined(__x86_64__)

__attribute__((target("avx2"), noinline))
uint64_t read_avx2(const uint8_t *data, size_t size, uint64_t iterations) {
    __m256i a0 = _mm256_setzero_si256();
    __m256i a1 = _mm256_setzero_si256();
    __m256i a2 = _mm256_setzero_si256();
    __m256i a3 = _mm256_setzero_si256();
    __m256i a4 = _mm256_setzero_si256();
    __m256i a5 = _mm256_setzero_si256();
    __m256i a6 = _mm256_setzero_si256();
    __m256i a7 = _mm256_setzero_si256();
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        for (size_t offset = 0; offset < size; offset += 256) {
            a0 = _mm256_xor_si256(a0, _mm256_load_si256(reinterpret_cast<const __m256i *>(data + offset)));
            a1 = _mm256_xor_si256(a1, _mm256_load_si256(reinterpret_cast<const __m256i *>(data + offset + 32)));
            a2 = _mm256_xor_si256(a2, _mm256_load_si256(reinterpret_cast<const __m256i *>(data + offset + 64)));
            a3 = _mm256_xor_si256(a3, _mm256_load_si256(reinterpret_cast<const __m256i *>(data + offset + 96)));
            a4 = _mm256_xor_si256(a4, _mm256_load_si256(reinterpret_cast<const __m256i *>(data + offset + 128)));
            a5 = _mm256_xor_si256(a5, _mm256_load_si256(reinterpret_cast<const __m256i *>(data + offset + 160)));
            a6 = _mm256_xor_si256(a6, _mm256_load_si256(reinterpret_cast<const __m256i *>(data + offset + 192)));
            a7 = _mm256_xor_si256(a7, _mm256_load_si256(reinterpret_cast<const __m256i *>(data + offset + 224)));
        }
        __asm__ volatile("" : "+x"(a0), "+x"(a1), "+x"(a2), "+x"(a3),
                             "+x"(a4), "+x"(a5), "+x"(a6), "+x"(a7) : : "memory");
    }
    const __m256i x01 = _mm256_xor_si256(a0, a1);
    const __m256i x23 = _mm256_xor_si256(a2, a3);
    const __m256i x45 = _mm256_xor_si256(a4, a5);
    const __m256i x67 = _mm256_xor_si256(a6, a7);
    const __m256i accumulator = _mm256_xor_si256(_mm256_xor_si256(x01, x23), _mm256_xor_si256(x45, x67));
    alignas(32) uint64_t lanes[4];
    _mm256_store_si256(reinterpret_cast<__m256i *>(lanes), accumulator);
    return lanes[0] ^ lanes[1] ^ lanes[2] ^ lanes[3];
}

__attribute__((target("avx2"), noinline))
uint64_t write_avx2(uint8_t *data, size_t size, uint64_t iterations) {
    const __m256i pattern = _mm256_set1_epi64x(0x5a5a5a5a5a5a5a5aULL);
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        for (size_t offset = 0; offset < size; offset += 256) {
            _mm256_store_si256(reinterpret_cast<__m256i *>(data + offset), pattern);
            _mm256_store_si256(reinterpret_cast<__m256i *>(data + offset + 32), pattern);
            _mm256_store_si256(reinterpret_cast<__m256i *>(data + offset + 64), pattern);
            _mm256_store_si256(reinterpret_cast<__m256i *>(data + offset + 96), pattern);
            _mm256_store_si256(reinterpret_cast<__m256i *>(data + offset + 128), pattern);
            _mm256_store_si256(reinterpret_cast<__m256i *>(data + offset + 160), pattern);
            _mm256_store_si256(reinterpret_cast<__m256i *>(data + offset + 192), pattern);
            _mm256_store_si256(reinterpret_cast<__m256i *>(data + offset + 224), pattern);
        }
        __asm__ volatile("" : : "r"(data) : "memory");
    }
    return *reinterpret_cast<const uint64_t *>(data + size - sizeof(uint64_t));
}

__attribute__((target("avx2"), noinline))
uint64_t copy_avx2(const uint8_t *source, uint8_t *destination, size_t size, uint64_t iterations) {
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        for (size_t offset = 0; offset < size; offset += 256) {
            const __m256i v0 = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset));
            const __m256i v1 = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset + 32));
            const __m256i v2 = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset + 64));
            const __m256i v3 = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset + 96));
            const __m256i v4 = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset + 128));
            const __m256i v5 = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset + 160));
            const __m256i v6 = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset + 192));
            const __m256i v7 = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset + 224));
            _mm256_store_si256(reinterpret_cast<__m256i *>(destination + offset), v0);
            _mm256_store_si256(reinterpret_cast<__m256i *>(destination + offset + 32), v1);
            _mm256_store_si256(reinterpret_cast<__m256i *>(destination + offset + 64), v2);
            _mm256_store_si256(reinterpret_cast<__m256i *>(destination + offset + 96), v3);
            _mm256_store_si256(reinterpret_cast<__m256i *>(destination + offset + 128), v4);
            _mm256_store_si256(reinterpret_cast<__m256i *>(destination + offset + 160), v5);
            _mm256_store_si256(reinterpret_cast<__m256i *>(destination + offset + 192), v6);
            _mm256_store_si256(reinterpret_cast<__m256i *>(destination + offset + 224), v7);
        }
        __asm__ volatile("" : : "r"(source), "r"(destination) : "memory");
    }
    return *reinterpret_cast<const uint64_t *>(destination + size - sizeof(uint64_t));
}

__attribute__((target("avx2"), noinline))
uint64_t stream_write_avx2(uint8_t *data, size_t size, uint64_t iterations) {
    const __m256i pattern = _mm256_set1_epi64x(0x5a5a5a5a5a5a5a5aULL);
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        for (size_t offset = 0; offset < size; offset += 256) {
            for (size_t lane = 0; lane < 256; lane += 32) {
                _mm256_stream_si256(reinterpret_cast<__m256i *>(data + offset + lane), pattern);
            }
        }
        _mm_sfence();
        __asm__ volatile("" : : "r"(data) : "memory");
    }
    return *reinterpret_cast<const uint64_t *>(data + size - sizeof(uint64_t));
}

__attribute__((target("avx2"), noinline))
uint64_t stream_copy_avx2(const uint8_t *source, uint8_t *destination, size_t size, uint64_t iterations) {
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        for (size_t offset = 0; offset < size; offset += 256) {
            for (size_t lane = 0; lane < 256; lane += 32) {
                const __m256i value = _mm256_load_si256(reinterpret_cast<const __m256i *>(source + offset + lane));
                _mm256_stream_si256(reinterpret_cast<__m256i *>(destination + offset + lane), value);
            }
        }
        _mm_sfence();
        __asm__ volatile("" : : "r"(source), "r"(destination) : "memory");
    }
    return *reinterpret_cast<const uint64_t *>(destination + size - sizeof(uint64_t));
}

bool avx2_available() { return __builtin_cpu_supports("avx2"); }

#elif defined(__aarch64__)

__attribute__((noinline))
uint64_t read_neon(const uint8_t *data, size_t size, uint64_t iterations) {
    uint8x16_t accumulators[16]{};
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        for (size_t offset = 0; offset < size; offset += 256) {
            for (size_t lane = 0; lane < 16; ++lane) {
                accumulators[lane] = veorq_u8(
                    accumulators[lane], vld1q_u8(data + offset + lane * 16)
                );
            }
        }
        __asm__ volatile("" : "+w"(accumulators[0]), "+w"(accumulators[1]),
                             "+w"(accumulators[2]), "+w"(accumulators[3]),
                             "+w"(accumulators[4]), "+w"(accumulators[5]),
                             "+w"(accumulators[6]), "+w"(accumulators[7]),
                             "+w"(accumulators[8]), "+w"(accumulators[9]),
                             "+w"(accumulators[10]), "+w"(accumulators[11]),
                             "+w"(accumulators[12]), "+w"(accumulators[13]),
                             "+w"(accumulators[14]), "+w"(accumulators[15]) : : "memory");
    }
    uint8x16_t result = accumulators[0];
    for (size_t lane = 1; lane < 16; ++lane) result = veorq_u8(result, accumulators[lane]);
    const uint64x2_t words = vreinterpretq_u64_u8(result);
    return vgetq_lane_u64(words, 0) ^ vgetq_lane_u64(words, 1);
}

__attribute__((noinline))
uint64_t write_neon(uint8_t *data, size_t size, uint64_t iterations) {
    const uint8x16_t pattern = vdupq_n_u8(0x5a);
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        for (size_t offset = 0; offset < size; offset += 256) {
            for (size_t lane = 0; lane < 16; ++lane) {
                vst1q_u8(data + offset + lane * 16, pattern);
            }
        }
        __asm__ volatile("" : : "r"(data) : "memory");
    }
    return *reinterpret_cast<const uint64_t *>(data + size - sizeof(uint64_t));
}

__attribute__((noinline))
uint64_t copy_neon(const uint8_t *source, uint8_t *destination, size_t size, uint64_t iterations) {
    for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
        for (size_t offset = 0; offset < size; offset += 256) {
            uint8x16_t values[16];
            for (size_t lane = 0; lane < 16; ++lane) {
                values[lane] = vld1q_u8(source + offset + lane * 16);
            }
            for (size_t lane = 0; lane < 16; ++lane) {
                vst1q_u8(destination + offset + lane * 16, values[lane]);
            }
        }
        __asm__ volatile("" : : "r"(source), "r"(destination) : "memory");
    }
    return *reinterpret_cast<const uint64_t *>(destination + size - sizeof(uint64_t));
}

#endif

using ThroughputKernel = uint64_t (*)(uint8_t *, uint8_t *, size_t, uint64_t);

struct alignas(64) WorkerResult {
    uint64_t checksum = 0;
};

struct ParallelBuffers {
    std::vector<AlignedBuffer> sources;
    std::vector<AlignedBuffer> destinations;

    ParallelBuffers(uint32_t worker_count, size_t bytes_per_worker) {
        sources.reserve(worker_count);
        destinations.reserve(worker_count);
        for (uint32_t worker = 0; worker < worker_count; ++worker) {
            sources.emplace_back(bytes_per_worker);
            destinations.emplace_back(bytes_per_worker);
        }
    }

    bool valid() const {
        return std::all_of(sources.begin(), sources.end(), [](const AlignedBuffer &buffer) {
            return static_cast<bool>(buffer);
        }) && std::all_of(destinations.begin(), destinations.end(), [](const AlignedBuffer &buffer) {
            return static_cast<bool>(buffer);
        });
    }

    void prefault_all() {
        for (AlignedBuffer &buffer : sources) prefault(buffer.data, buffer.size);
        for (AlignedBuffer &buffer : destinations) prefault(buffer.data, buffer.size);
    }
};

uint64_t read_adapter(uint8_t *source, uint8_t *, size_t size, uint64_t iterations) {
#if defined(__x86_64__)
    return read_avx2(source, size, iterations);
#elif defined(__aarch64__)
    return read_neon(source, size, iterations);
#else
    (void)source; (void)size; (void)iterations;
    return 0;
#endif
}

uint64_t write_adapter(uint8_t *, uint8_t *destination, size_t size, uint64_t iterations) {
#if defined(__x86_64__)
    return write_avx2(destination, size, iterations);
#elif defined(__aarch64__)
    return write_neon(destination, size, iterations);
#else
    (void)destination; (void)size; (void)iterations;
    return 0;
#endif
}

uint64_t copy_adapter(uint8_t *source, uint8_t *destination, size_t size, uint64_t iterations) {
#if defined(__x86_64__)
    return copy_avx2(source, destination, size, iterations);
#elif defined(__aarch64__)
    return copy_neon(source, destination, size, iterations);
#else
    (void)source; (void)destination; (void)size; (void)iterations;
    return 0;
#endif
}

uint64_t stream_write_adapter(uint8_t *, uint8_t *destination, size_t size, uint64_t iterations) {
#if defined(__x86_64__)
    return stream_write_avx2(destination, size, iterations);
#elif defined(__aarch64__)
    return write_neon(destination, size, iterations);
#else
    (void)destination; (void)size; (void)iterations;
    return 0;
#endif
}

uint64_t stream_copy_adapter(uint8_t *source, uint8_t *destination, size_t size, uint64_t iterations) {
#if defined(__x86_64__)
    return stream_copy_avx2(source, destination, size, iterations);
#elif defined(__aarch64__)
    return copy_neon(source, destination, size, iterations);
#else
    (void)source; (void)destination; (void)size; (void)iterations;
    return 0;
#endif
}

class PersistentWorkerTeam {
public:
    PersistentWorkerTeam(ThroughputKernel kernel, ParallelBuffers &buffers, size_t bytes_per_worker)
        : kernel_(kernel), buffers_(buffers), bytes_per_worker_(bytes_per_worker),
          results_(buffers.sources.size()) {
        workers_.reserve(buffers.sources.size());
        try {
            for (uint32_t worker = 0; worker < buffers.sources.size(); ++worker) {
                workers_.emplace_back([this, worker] { worker_loop(worker); });
            }
        } catch (...) {
            stop_and_join_workers();
            throw;
        }
        std::unique_lock lock(mutex_);
        ready_condition_.wait(lock, [this] { return ready_count_ == workers_.size(); });
    }

    ~PersistentWorkerTeam() { stop_and_join_workers(); }

    PersistentWorkerTeam(const PersistentWorkerTeam &) = delete;
    PersistentWorkerTeam &operator=(const PersistentWorkerTeam &) = delete;

    double run(uint64_t iterations) {
        uint64_t start = 0;
        {
            std::lock_guard lock(mutex_);
            iterations_ = iterations;
            completed_count_ = 0;
            start = now_ticks();
            ++generation_;
        }
        command_condition_.notify_all();

        uint64_t end = 0;
        {
            std::unique_lock lock(mutex_);
            completion_condition_.wait(lock, [this] { return completed_count_ == workers_.size(); });
            end = end_ticks_;
        }
        for (const WorkerResult &result : results_) g_observable_sink ^= result.checksum;
        return elapsed_nanoseconds(start, end);
    }

private:
    void stop_and_join_workers() noexcept {
        {
            std::lock_guard lock(mutex_);
            stopping_ = true;
            ++generation_;
        }
        command_condition_.notify_all();
        for (std::thread &worker : workers_) {
            if (worker.joinable()) worker.join();
        }
    }

    void worker_loop(uint32_t worker) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        uint64_t observed_generation = 0;
        {
            std::lock_guard lock(mutex_);
            ++ready_count_;
        }
        ready_condition_.notify_one();

        while (true) {
            uint64_t iterations = 0;
            {
                std::unique_lock lock(mutex_);
                command_condition_.wait(lock, [this, &observed_generation] {
                    return stopping_ || generation_ != observed_generation;
                });
                if (stopping_) return;
                observed_generation = generation_;
                iterations = iterations_;
            }
            results_[worker].checksum = kernel_(
                buffers_.sources[worker].data,
                buffers_.destinations[worker].data,
                bytes_per_worker_,
                iterations
            );
            {
                std::lock_guard lock(mutex_);
                if (++completed_count_ == workers_.size()) {
                    end_ticks_ = now_ticks();
                    completion_condition_.notify_one();
                }
            }
        }
    }

    ThroughputKernel kernel_;
    ParallelBuffers &buffers_;
    size_t bytes_per_worker_;
    std::vector<WorkerResult> results_;
    std::vector<std::thread> workers_;
    std::mutex mutex_;
    std::condition_variable ready_condition_;
    std::condition_variable command_condition_;
    std::condition_variable completion_condition_;
    size_t ready_count_ = 0;
    size_t completed_count_ = 0;
    uint64_t generation_ = 0;
    uint64_t iterations_ = 0;
    uint64_t end_ticks_ = 0;
    bool stopping_ = false;
};

std::vector<double> measure_parallel_throughput(
    ThroughputKernel kernel,
    ParallelBuffers &buffers,
    size_t bytes_per_worker,
    const A128Configuration &configuration,
    double traffic_factor = 1.0,
    const std::function<void(A128ProgressPhase, uint32_t)> &progress = {}
) {
    PersistentWorkerTeam team(kernel, buffers, bytes_per_worker);
    if (progress) progress(A128_PROGRESS_CALIBRATING, 0);
    uint64_t iterations = 1;
    while (iterations < (1ULL << 40)) {
        const double duration = team.run(iterations);
        if (duration >= static_cast<double>(configuration.minimum_sample_nanoseconds) / 4.0) {
            const double scale = static_cast<double>(configuration.minimum_sample_nanoseconds) /
                                 std::max(duration, 1.0);
            iterations = std::max<uint64_t>(1, static_cast<uint64_t>(std::ceil(iterations * scale)));
            break;
        }
        iterations *= 2;
    }
    std::vector<double> samples;
    samples.reserve(configuration.sample_count);
    for (uint32_t sample = 0; sample < configuration.sample_count; ++sample) {
        const double nanoseconds = team.run(iterations);
        const long double bytes = static_cast<long double>(bytes_per_worker) * iterations *
                                  static_cast<long double>(buffers.sources.size()) * traffic_factor;
        samples.push_back(static_cast<double>(bytes / nanoseconds)); // bytes/ns == decimal GB/s
        if (progress) progress(A128_PROGRESS_SAMPLE_COMPLETED, sample + 1);
    }
    return samples;
}

struct LatencyNode { uint64_t next; uint8_t padding[56]; };
static_assert(sizeof(LatencyNode) == 64);

std::vector<double> measure_latency(
    uint8_t *storage,
    size_t size,
    const A128Configuration &configuration,
    const std::function<void(A128ProgressPhase, uint32_t)> &progress = {}
) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    const size_t node_count = size / sizeof(LatencyNode);
    auto *nodes = reinterpret_cast<LatencyNode *>(storage);
    std::vector<uint64_t> order(node_count);
    std::iota(order.begin(), order.end(), 0);
    std::mt19937_64 generator(0xA128ULL ^ size);
    std::shuffle(order.begin(), order.end(), generator);
    for (size_t index = 0; index < node_count; ++index) {
        nodes[order[index]].next = order[(index + 1) % node_count];
    }

    uint64_t accesses = std::max<uint64_t>(node_count, 1);
    uint64_t cursor = 0;
    if (progress) progress(A128_PROGRESS_CALIBRATING, 0);
    while (true) {
        const uint64_t start = now_ticks();
        for (uint64_t access = 0; access < accesses; ++access) cursor = nodes[cursor].next;
        const double duration = elapsed_nanoseconds(start, now_ticks());
        g_observable_sink ^= cursor;
        if (duration >= static_cast<double>(configuration.minimum_sample_nanoseconds) / 4.0) {
            const double scale = static_cast<double>(configuration.minimum_sample_nanoseconds) /
                                 std::max(duration, 1.0);
            accesses = std::max<uint64_t>(1, static_cast<uint64_t>(std::ceil(accesses * scale)));
            break;
        }
        accesses *= 2;
    }

    std::vector<double> samples;
    samples.reserve(configuration.sample_count);
    for (uint32_t sample = 0; sample < configuration.sample_count; ++sample) {
        const uint64_t start = now_ticks();
        for (uint64_t access = 0; access < accesses; ++access) cursor = nodes[cursor].next;
        const double duration = elapsed_nanoseconds(start, now_ticks());
        g_observable_sink ^= cursor;
        samples.push_back(duration / static_cast<double>(accesses));
        if (progress) progress(A128_PROGRESS_SAMPLE_COMPLETED, sample + 1);
    }
    return samples;
}

double best_throughput(const std::vector<double> &samples) {
    return *std::max_element(samples.begin(), samples.end());
}

double best_latency(const std::vector<double> &samples) {
    return *std::min_element(samples.begin(), samples.end());
}

double relative_spread(const std::vector<double> &samples) {
    const auto [minimum, maximum] = std::minmax_element(samples.begin(), samples.end());
    const double midpoint = (*minimum + *maximum) / 2.0;
    return midpoint > 0.0 ? (*maximum - *minimum) / midpoint : 0.0;
}

size_t aligned_working_set(uint64_t desired) {
    const uint64_t bounded = std::max<uint64_t>(desired, 4 * 1024);
    return static_cast<size_t>((bounded / kKernelQuantum) * kKernelQuantum);
}

constexpr uint64_t saturating_multiply(uint64_t value, uint64_t factor) {
    return value > std::numeric_limits<uint64_t>::max() / factor
        ? std::numeric_limits<uint64_t>::max()
        : value * factor;
}

constexpr bool is_usable_l3_capacity(uint64_t l2_bytes, uint64_t l3_bytes) {
    return l2_bytes > 0 && l2_bytes <= l3_bytes / 2;
}

bool has_usable_l3(const A128SystemInfo &system) {
    return is_usable_l3_capacity(system.l2_bytes, system.l3_bytes);
}

static_assert(saturating_multiply(7, 4) == 28);
static_assert(saturating_multiply(std::numeric_limits<uint64_t>::max(), 2) ==
              std::numeric_limits<uint64_t>::max());
static_assert(!is_usable_l3_capacity(1, 0));
static_assert(!is_usable_l3_capacity(8, 8));
static_assert(!is_usable_l3_capacity(8, 15));
static_assert(is_usable_l3_capacity(8, 16));

std::array<size_t, 4> working_sets(const A128SystemInfo &system) {
    const uint64_t l1 = aligned_working_set(system.l1_data_bytes / 2);
    const uint64_t l2 = aligned_working_set(std::max(
        saturating_multiply(system.l1_data_bytes, 2), system.l2_bytes / 2
    ));
    const uint64_t l3 = !has_usable_l3(system)
        ? 0
        : aligned_working_set(std::max(
            saturating_multiply(system.l2_bytes, 2), system.l3_bytes / 2
        ));
    const uint64_t memory_floor = std::max<uint64_t>(
        saturating_multiply(system.l3_bytes, 4), 128ULL * 1024 * 1024
    );
    const uint64_t memory_cap = std::max<uint64_t>(128ULL * 1024 * 1024, system.memory_bytes / 8);
    const uint64_t memory = aligned_working_set(std::min<uint64_t>(memory_floor, memory_cap));
    return {static_cast<size_t>(l1), static_cast<size_t>(l2), static_cast<size_t>(l3), static_cast<size_t>(memory)};
}

A128LevelMask available_level_mask(const A128SystemInfo &system) {
    A128LevelMask mask = A128_LEVEL_MASK_L1 | A128_LEVEL_MASK_L2 | A128_LEVEL_MASK_MEMORY;
    if (has_usable_l3(system)) mask |= A128_LEVEL_MASK_L3;
    return mask;
}

size_t bytes_per_worker(A128Level level, size_t logical_working_set, uint32_t worker_count) {
    if (level == A128_LEVEL_L1 || level == A128_LEVEL_L2) return logical_working_set;
    return aligned_working_set(logical_working_set / std::max<uint32_t>(worker_count, 1));
}

void store_throughput_measurement(
    A128Measurement &measurement,
    A128Level level,
    A128Scope scope,
    size_t working_set_bytes,
    const std::vector<double> &reads,
    const std::vector<double> &writes,
    const std::vector<double> &copies
) {
    measurement.level = level;
    measurement.scope = scope;
    measurement.available_metrics = A128_METRIC_READ | A128_METRIC_WRITE | A128_METRIC_COPY;
    measurement.working_set_bytes = working_set_bytes;
    measurement.read_gigabytes_per_second = best_throughput(reads);
    measurement.write_gigabytes_per_second = best_throughput(writes);
    measurement.copy_gigabytes_per_second = best_throughput(copies);
    measurement.maximum_relative_spread = std::max({
        relative_spread(reads), relative_spread(writes), relative_spread(copies)
    });
}

uint32_t popcount32(uint32_t value) {
    return static_cast<uint32_t>(__builtin_popcount(value));
}

void emit_progress(
    A128ProgressCallback callback,
    void *context,
    A128ProgressPhase phase,
    A128Level level,
    uint32_t metric,
    uint32_t completed_stages,
    uint32_t total_stages,
    uint32_t completed_samples,
    uint32_t sample_count,
    const A128Measurement &measurement
) {
    if (!callback) return;
    A128ProgressEvent event{};
    event.struct_size = sizeof(event);
    event.phase = phase;
    event.level = level;
    event.metric = metric;
    event.completed_stage_count = completed_stages;
    event.total_stage_count = total_stages;
    event.completed_sample_count = completed_samples;
    event.sample_count = sample_count;
    event.measurement = measurement;
    callback(context, &event);
}

} // namespace

extern "C" A128Configuration a128_default_configuration(void) noexcept {
    return A128Configuration{5, 200'000'000ULL, 0};
}

extern "C" A128Status a128_read_system_info(A128SystemInfo *output) noexcept {
    try {
    if (!output) return A128_STATUS_INVALID_ARGUMENT;
    std::memset(output, 0, sizeof(*output));
#if defined(__x86_64__)
    copy_string(output->architecture, sizeof(output->architecture), "x86_64");
    if (!avx2_available()) return A128_STATUS_UNSUPPORTED_ARCHITECTURE;
    copy_string(output->backend, sizeof(output->backend), "AVX2 cached");
    copy_string(output->cpu_name, sizeof(output->cpu_name), read_string_sysctl("machdep.cpu.brand_string"));
    const RawCPUIdentity identity = raw_cpu_identity();
    output->cpu_family = identity.family;
    output->cpu_model = identity.model;
    output->cpu_stepping = identity.stepping;
    output->cpu_signature = identity.signature;
    output->cpu_base_megahertz = identity.base_megahertz;
    output->cpu_max_megahertz = identity.max_megahertz;
    output->reference_clock_megahertz = identity.reference_megahertz;
    if (identity.family == 6 && identity.model == 0xb7) {
        copy_string(output->cpu_microarchitecture, sizeof(output->cpu_microarchitecture), "Raptor Lake-S");
        copy_string(output->cpu_socket, sizeof(output->cpu_socket), "LGA1700");
    } else {
        char model[48]{};
        std::snprintf(model, sizeof(model), "CPUID family %u model 0x%02X", identity.family, identity.model);
        copy_string(output->cpu_microarchitecture, sizeof(output->cpu_microarchitecture), model);
    }
    copy_string(output->cpu_features, sizeof(output->cpu_features), normalized_feature_list());
#elif defined(__aarch64__)
    copy_string(output->architecture, sizeof(output->architecture), "arm64");
    copy_string(output->backend, sizeof(output->backend), "ARM NEON cached");
    std::string cpu_name = read_string_sysctl("machdep.cpu.brand_string");
    if (cpu_name.empty()) cpu_name = read_string_sysctl("hw.model");
    copy_string(output->cpu_name, sizeof(output->cpu_name), cpu_name);
    copy_string(output->cpu_microarchitecture, sizeof(output->cpu_microarchitecture), "Apple Silicon");
    copy_string(output->cpu_socket, sizeof(output->cpu_socket), "SoC package");
    copy_string(output->cpu_features, sizeof(output->cpu_features), "ARM64 NEON ASIMD");
#else
    return A128_STATUS_UNSUPPORTED_ARCHITECTURE;
#endif
    output->memory_bytes = read_uint64_sysctl("hw.memsize");
    output->l1_data_bytes = read_uint64_sysctl("hw.l1dcachesize");
    output->l2_bytes = read_uint64_sysctl("hw.l2cachesize");
    output->l3_bytes = read_uint64_sysctl("hw.l3cachesize");
    output->logical_cpu_count = static_cast<uint32_t>(read_uint64_sysctl("hw.logicalcpu"));
    output->microcode_version = static_cast<uint32_t>(read_uint64_sysctl("machdep.cpu.microcode_version"));
    const PlatformDiscovery platform = discover_platform();
    copy_string(output->memory_type, sizeof(output->memory_type), platform.memory_type);
    copy_string(output->memory_manufacturer, sizeof(output->memory_manufacturer), platform.memory_manufacturer);
    copy_string(output->memory_part_number, sizeof(output->memory_part_number), platform.memory_part_number);
    copy_string(output->platform_name, sizeof(output->platform_name), platform.platform_name);
    copy_string(output->motherboard, sizeof(output->motherboard), platform.motherboard);
    copy_string(output->chipset, sizeof(output->chipset), platform.chipset);
    copy_string(output->firmware, sizeof(output->firmware), platform.firmware);
    output->memory_data_rate = platform.memory_data_rate;
    output->memory_module_count = platform.memory_module_count;
    if (output->memory_bytes == 0 || output->l1_data_bytes == 0 || output->l2_bytes == 0) {
        return A128_STATUS_SYSTEM_ERROR;
    }
    return A128_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return A128_STATUS_ALLOCATION_FAILED;
    } catch (...) {
        return A128_STATUS_SYSTEM_ERROR;
    }
}

extern "C" A128Status a128_read_system_info_v2(
    A128SystemInfoV2 *output,
    size_t output_size
) noexcept {
    try {
        if (!output || output_size < A128_SYSTEM_INFO_V2_MIN_SIZE) {
            return A128_STATUS_INVALID_ARGUMENT;
        }

        A128SystemInfoV2 discovered{};
        discovered.struct_size = static_cast<uint32_t>(std::min(output_size, sizeof(discovered)));
        discovered.schema_version = A128_SYSTEM_INFO_V2_SCHEMA_VERSION;
        const A128Status legacy_status = a128_read_system_info(&discovered.legacy);
        if (legacy_status != A128_STATUS_OK) return legacy_status;
        discovered.physical_core_count = static_cast<uint32_t>(read_uint64_sysctl("hw.physicalcpu"));
        copy_string(discovered.hardware_model, sizeof(discovered.hardware_model), read_string_sysctl("hw.model"));
        const PlatformDiscovery platform = discover_platform();
        copy_string(discovered.board_identifier, sizeof(discovered.board_identifier), platform.board_identifier);
        copy_string(discovered.system_firmware, sizeof(discovered.system_firmware), platform.firmware);

#if defined(__aarch64__)
        copy_string(discovered.soc_name, sizeof(discovered.soc_name), discovered.legacy.cpu_name);
        const AppleSoCSpecification *specification = apple_soc_specification(discovered.legacy.cpu_name);
        if (specification) {
            copy_string(discovered.soc_identifier, sizeof(discovered.soc_identifier), specification->identifier);
            copy_string(discovered.process_node, sizeof(discovered.process_node), specification->process_node);
            copy_string(discovered.instruction_set, sizeof(discovered.instruction_set), specification->instruction_set);
            copy_string(discovered.memory_technology, sizeof(discovered.memory_technology), specification->memory_technology);
            discovered.performance_max_megahertz = specification->performance_max_megahertz;
            discovered.efficiency_max_megahertz = specification->efficiency_max_megahertz;
            discovered.neural_engine_core_count = specification->neural_engine_cores;
            discovered.memory_bandwidth_gigabytes_per_second = specification->memory_bandwidth_gigabytes_per_second;
            discovered.memory_data_rate_mtps = specification->memory_data_rate_mtps;
            discovered.system_cache_bytes = specification->system_cache_bytes;
            store_provenance(
                discovered.soc_provenance, A128_PROVENANCE_MAPPED,
                "https://www.apple.com/macbook-air/specs/ + Aida128 SoC catalog",
                "SoC identity, process, and ISA are catalog metadata; runtime core topology is reported separately."
            );
            store_provenance(
                discovered.clock_provenance, A128_PROVENANCE_MAPPED,
                "https://www.notebookcheck.net/Analysis-of-the-Apple-M5-SoC-Apple-silicon-extends-its-lead-over-AMD-Intel-and-Qualcomm.1144213.0.html",
                "Maximum observed P/E clocks; these are not live frequencies reported by macOS."
            );
            store_provenance(
                discovered.memory_provenance, A128_PROVENANCE_MAPPED,
                "https://www.apple.com/macbook-air/specs/ + Aida128 SoC catalog",
                "Unified-memory bandwidth is an Apple specification; technology and data rate are catalog data."
            );
            store_provenance(
                discovered.system_cache_provenance, A128_PROVENANCE_EXPERIMENTAL,
                "https://www.michaelstinkerings.org/apple-m5-gpu-roofline-analysis/",
                "Approximate 32 MiB SLC capacity. Benchmark values are CPU-observed system-cache performance."
            );
        }

        for (uint32_t index = 0; index < A128_MAX_PERFORMANCE_LEVELS; ++index) {
            char key[64]{};
            std::snprintf(key, sizeof(key), "hw.perflevel%u.physicalcpu", index);
            const uint64_t physical = read_uint64_sysctl(key);
            if (physical == 0) break;
            A128PerformanceLevel &level = discovered.performance_levels[discovered.performance_level_count++];
            std::snprintf(key, sizeof(key), "hw.perflevel%u.name", index);
            copy_string(level.name, sizeof(level.name), read_string_sysctl(key));
            level.physical_core_count = static_cast<uint32_t>(physical);
            std::snprintf(key, sizeof(key), "hw.perflevel%u.logicalcpu", index);
            level.logical_cpu_count = static_cast<uint32_t>(read_uint64_sysctl(key));
            std::snprintf(key, sizeof(key), "hw.perflevel%u.l1icachesize", index);
            level.l1_instruction_bytes = read_uint64_sysctl(key);
            std::snprintf(key, sizeof(key), "hw.perflevel%u.l1dcachesize", index);
            level.l1_data_bytes = read_uint64_sysctl(key);
            std::snprintf(key, sizeof(key), "hw.perflevel%u.l2cachesize", index);
            level.l2_bytes = read_uint64_sysctl(key);
            const std::string level_name = level.name;
            if (level_name == "Performance" || level_name == "P") {
                discovered.performance_core_count += level.physical_core_count;
            } else if (level_name == "Efficiency" || level_name == "E") {
                discovered.efficiency_core_count += level.physical_core_count;
            }
        }
        if (discovered.performance_level_count > 0) {
            store_provenance(
                discovered.topology_provenance, A128_PROVENANCE_REPORTED,
                "sysctl hw.perflevel*",
                "Core groups and private/shared cache capacities reported by the running macOS kernel."
            );
        }
#else
        copy_string(discovered.instruction_set, sizeof(discovered.instruction_set), "x86_64 AVX2");
        store_provenance(
            discovered.topology_provenance, A128_PROVENANCE_REPORTED,
            "CPUID + sysctl hw.logicalcpu/hw.physicalcpu",
            "Scheduler-visible host topology."
        );
#endif

        if (!platform.firmware.empty()) {
            store_provenance(
                discovered.firmware_provenance,
                platform.firmware.find("Synthetic") == 0 ? A128_PROVENANCE_SYNTHETIC : A128_PROVENANCE_REPORTED,
                "IODeviceTree /rom",
                "Firmware identity exposed through the platform registry."
            );
        }

        std::memcpy(output, &discovered, std::min(output_size, sizeof(discovered)));
        return A128_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return A128_STATUS_ALLOCATION_FAILED;
    } catch (...) {
        return A128_STATUS_SYSTEM_ERROR;
    }
}

extern "C" A128Status a128_run_benchmark(
    const A128Configuration *configuration,
    A128Report *output
) noexcept {
    try {
    if (!configuration || !output || configuration->sample_count < 3 ||
        configuration->sample_count > 100 || configuration->minimum_sample_nanoseconds < 10'000'000ULL) {
        return A128_STATUS_INVALID_ARGUMENT;
    }
    const BenchmarkRunLease run_lease;
    if (!run_lease) return A128_STATUS_BUSY;
    std::memset(output, 0, sizeof(*output));
    const A128Status info_status = a128_read_system_info(&output->system);
    if (info_status != A128_STATUS_OK) return info_status;

    const auto sizes = working_sets(output->system);
    if (configuration->throughput_worker_count > output->system.logical_cpu_count) {
        return A128_STATUS_INVALID_ARGUMENT;
    }
    const uint32_t worker_count = configuration->throughput_worker_count == 0
        ? std::max<uint32_t>(output->system.logical_cpu_count, 1)
        : configuration->throughput_worker_count;
    output->throughput_worker_count = worker_count;

    uint32_t measurement_index = 0;
    for (size_t index = 0; index < sizes.size(); ++index) {
        if (sizes[index] == 0) continue;
        const A128Level level = static_cast<A128Level>(index);
        const size_t latency_size = sizes[index];
        AlignedBuffer latency_buffer(latency_size);
        ParallelBuffers single_buffers(1, sizes[index]);
        if (!single_buffers.valid() || !latency_buffer) return A128_STATUS_ALLOCATION_FAILED;
        single_buffers.prefault_all();
        prefault(latency_buffer.data, latency_buffer.size);
        const auto single_reads = measure_parallel_throughput(
            read_adapter, single_buffers, sizes[index], *configuration
        );
        const auto single_writes = measure_parallel_throughput(
            write_adapter, single_buffers, sizes[index], *configuration
        );
        const size_t single_copy_bytes = level == A128_LEVEL_MEMORY ? sizes[index] : sizes[index] / 2;
        const auto single_copies = measure_parallel_throughput(
            copy_adapter, single_buffers, single_copy_bytes, *configuration,
            level == A128_LEVEL_MEMORY ? 1.0 : 2.0
        );
        const auto latencies = measure_latency(latency_buffer.data, latency_size, *configuration);
        A128Measurement &single = output->measurements[measurement_index++];
        store_throughput_measurement(
            single, level, A128_SCOPE_SINGLE_WORKER, sizes[index],
            single_reads, single_writes, single_copies
        );
        single.available_metrics |= A128_METRIC_LATENCY;
        single.latency_nanoseconds = best_latency(latencies);
        single.maximum_relative_spread = std::max(
            single.maximum_relative_spread, relative_spread(latencies)
        );

        {
            const uint32_t level_worker_count = level == A128_LEVEL_L3 && output->system.l3_bytes > 0
                ? std::max<uint32_t>(1, std::min<uint64_t>(
                    worker_count, output->system.l3_bytes / sizes[index]
                ))
                : worker_count;
            const size_t worker_size = bytes_per_worker(level, sizes[index], level_worker_count);
            ParallelBuffers aggregate_buffers(level_worker_count, worker_size);
            if (!aggregate_buffers.valid()) return A128_STATUS_ALLOCATION_FAILED;
            aggregate_buffers.prefault_all();
            const auto aggregate_reads = measure_parallel_throughput(
                read_adapter, aggregate_buffers, worker_size, *configuration
            );
            const ThroughputKernel aggregate_write_kernel = level == A128_LEVEL_MEMORY
                ? stream_write_adapter : write_adapter;
            const ThroughputKernel aggregate_copy_kernel = level == A128_LEVEL_MEMORY
                ? stream_copy_adapter : copy_adapter;
            const auto aggregate_writes = measure_parallel_throughput(
                aggregate_write_kernel, aggregate_buffers, worker_size, *configuration
            );
            const size_t aggregate_copy_bytes = level == A128_LEVEL_MEMORY
                ? worker_size : worker_size / 2;
            const auto aggregate_copies = measure_parallel_throughput(
                aggregate_copy_kernel, aggregate_buffers, aggregate_copy_bytes, *configuration,
                2.0
            );
            A128Measurement &aggregate = output->measurements[measurement_index++];
            store_throughput_measurement(
                aggregate, level, A128_SCOPE_AGGREGATE, worker_size * level_worker_count,
                aggregate_reads, aggregate_writes, aggregate_copies
            );
        }
    }
    output->measurement_count = measurement_index;
    return A128_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return A128_STATUS_ALLOCATION_FAILED;
    } catch (...) {
        return A128_STATUS_SYSTEM_ERROR;
    }
}

extern "C" A128Status a128_run_benchmark_v2(
    const A128RunConfiguration *configuration,
    A128ProgressCallback callback,
    void *context,
    A128Report *output
) noexcept {
    try {
    constexpr uint32_t kKnownLevelMask = A128_LEVEL_MASK_ALL;
    constexpr uint32_t kKnownMetricMask = A128_METRIC_MASK_ALL;
    if (!configuration || !output || configuration->struct_size < sizeof(A128RunConfiguration) ||
        configuration->level_mask == 0 || (configuration->level_mask & ~kKnownLevelMask) != 0 ||
        configuration->metric_mask == 0 || (configuration->metric_mask & ~kKnownMetricMask) != 0 ||
        configuration->sample_count < 3 || configuration->sample_count > 100 ||
        configuration->total_run_nanoseconds < 10'000'000ULL) {
        return A128_STATUS_INVALID_ARGUMENT;
    }

    const BenchmarkRunLease run_lease;
    if (!run_lease) return A128_STATUS_BUSY;
    std::memset(output, 0, sizeof(*output));
    const A128Status info_status = a128_read_system_info(&output->system);
    if (info_status != A128_STATUS_OK) return info_status;
    if (configuration->throughput_worker_count > output->system.logical_cpu_count) {
        return A128_STATUS_INVALID_ARGUMENT;
    }

    const uint32_t worker_count = configuration->throughput_worker_count == 0
        ? std::max<uint32_t>(output->system.logical_cpu_count, 1)
        : configuration->throughput_worker_count;
    output->throughput_worker_count = worker_count;
    const A128LevelMask effective_level_mask = configuration->level_mask &
                                               available_level_mask(output->system);
    if (effective_level_mask == 0) return A128_STATUS_LEVEL_UNAVAILABLE;
    const uint32_t total_stages = popcount32(effective_level_mask) *
                                  popcount32(configuration->metric_mask);
    const uint64_t per_sample_nanoseconds = std::max<uint64_t>(
        10'000'000ULL,
        configuration->total_run_nanoseconds /
            static_cast<uint64_t>(total_stages) / configuration->sample_count
    );
    const A128Configuration stage_configuration{
        configuration->sample_count,
        per_sample_nanoseconds,
        configuration->throughput_worker_count
    };
    const auto sizes = working_sets(output->system);
    const std::array<A128Level, 4> level_order{
        A128_LEVEL_MEMORY, A128_LEVEL_L1, A128_LEVEL_L2, A128_LEVEL_L3
    };
    const std::array<uint32_t, 4> metric_order{
        A128_METRIC_READ, A128_METRIC_WRITE, A128_METRIC_COPY, A128_METRIC_LATENCY
    };
    uint32_t completed_stages = 0;

    for (A128Level level : level_order) {
        if ((effective_level_mask & (1u << level)) == 0) continue;
        const size_t logical_size = sizes[static_cast<size_t>(level)];
        A128Measurement measurement{};
        measurement.level = level;
        measurement.scope = A128_SCOPE_AGGREGATE;
        measurement.working_set_bytes = logical_size;

        for (uint32_t metric : metric_order) {
            if ((configuration->metric_mask & metric) == 0) continue;
            emit_progress(
                callback, context, A128_PROGRESS_STAGE_STARTED, level, metric,
                completed_stages, total_stages, 0, configuration->sample_count, measurement
            );
            const auto stage_progress = [&](A128ProgressPhase phase, uint32_t completed_samples) {
                emit_progress(
                    callback, context, phase, level, metric, completed_stages, total_stages,
                    completed_samples, configuration->sample_count, measurement
                );
            };

            std::vector<double> samples;
            if (metric == A128_METRIC_LATENCY) {
                AlignedBuffer latency_buffer(logical_size);
                if (!latency_buffer) return A128_STATUS_ALLOCATION_FAILED;
                prefault(latency_buffer.data, latency_buffer.size);
                samples = measure_latency(
                    latency_buffer.data, logical_size, stage_configuration, stage_progress
                );
                measurement.latency_nanoseconds = best_latency(samples);
            } else {
                const uint32_t level_worker_count = level == A128_LEVEL_L3 && output->system.l3_bytes > 0
                    ? std::max<uint32_t>(1, std::min<uint64_t>(
                        worker_count, output->system.l3_bytes / logical_size
                    ))
                    : worker_count;
                const size_t worker_size = bytes_per_worker(level, logical_size, level_worker_count);
                ParallelBuffers buffers(level_worker_count, worker_size);
                if (!buffers.valid()) return A128_STATUS_ALLOCATION_FAILED;
                buffers.prefault_all();
                ThroughputKernel kernel = read_adapter;
                double traffic_factor = 1.0;
                size_t operation_size = worker_size;
                if (metric == A128_METRIC_WRITE) {
                    kernel = level == A128_LEVEL_MEMORY ? stream_write_adapter : write_adapter;
                } else if (metric == A128_METRIC_COPY) {
                    kernel = level == A128_LEVEL_MEMORY ? stream_copy_adapter : copy_adapter;
                    operation_size = level == A128_LEVEL_MEMORY ? worker_size : worker_size / 2;
                    traffic_factor = 2.0;
                }
                samples = measure_parallel_throughput(
                    kernel, buffers, operation_size, stage_configuration, traffic_factor, stage_progress
                );
                measurement.working_set_bytes = worker_size * level_worker_count;
                const double value = best_throughput(samples);
                if (metric == A128_METRIC_READ) measurement.read_gigabytes_per_second = value;
                if (metric == A128_METRIC_WRITE) measurement.write_gigabytes_per_second = value;
                if (metric == A128_METRIC_COPY) measurement.copy_gigabytes_per_second = value;
            }
            measurement.available_metrics |= metric;
            measurement.maximum_relative_spread = std::max(
                measurement.maximum_relative_spread, relative_spread(samples)
            );
            ++completed_stages;
            emit_progress(
                callback, context, A128_PROGRESS_STAGE_COMPLETED, level, metric,
                completed_stages, total_stages, configuration->sample_count,
                configuration->sample_count, measurement
            );
        }
        output->measurements[output->measurement_count++] = measurement;
    }

    A128Measurement empty{};
    emit_progress(
        callback, context, A128_PROGRESS_RUN_COMPLETED, A128_LEVEL_MEMORY, 0,
        completed_stages, total_stages, configuration->sample_count,
        configuration->sample_count, empty
    );
    return A128_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return A128_STATUS_ALLOCATION_FAILED;
    } catch (...) {
        return A128_STATUS_SYSTEM_ERROR;
    }
}

extern "C" const char *a128_status_message(A128Status status) noexcept {
    switch (status) {
        case A128_STATUS_OK: return "ok";
        case A128_STATUS_INVALID_ARGUMENT: return "invalid argument";
        case A128_STATUS_UNSUPPORTED_ARCHITECTURE: return "unsupported architecture or SIMD backend";
        case A128_STATUS_ALLOCATION_FAILED: return "aligned memory allocation failed";
        case A128_STATUS_SYSTEM_ERROR: return "required system information is unavailable";
        case A128_STATUS_BUSY: return "another benchmark run is already active";
        case A128_STATUS_LEVEL_UNAVAILABLE: return "none of the requested cache levels are available";
    }
    return "unknown benchmark status";
}
