#ifndef AIDA128_BENCHMARK_CORE_H
#define AIDA128_BENCHMARK_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define A128_NOEXCEPT noexcept
extern "C" {
#else
#define A128_NOEXCEPT
#endif

typedef enum A128Status {
    A128_STATUS_OK = 0,
    A128_STATUS_INVALID_ARGUMENT = 1,
    A128_STATUS_UNSUPPORTED_ARCHITECTURE = 2,
    A128_STATUS_ALLOCATION_FAILED = 3,
    A128_STATUS_SYSTEM_ERROR = 4,
    A128_STATUS_BUSY = 5
} A128Status;

typedef enum A128Level {
    A128_LEVEL_L1 = 0,
    A128_LEVEL_L2 = 1,
    A128_LEVEL_L3 = 2,
    A128_LEVEL_MEMORY = 3
} A128Level;

typedef enum A128Scope {
    A128_SCOPE_SINGLE_WORKER = 0,
    A128_SCOPE_AGGREGATE = 1
} A128Scope;

typedef enum A128MetricAvailability {
    A128_METRIC_READ = 1 << 0,
    A128_METRIC_WRITE = 1 << 1,
    A128_METRIC_COPY = 1 << 2,
    A128_METRIC_LATENCY = 1 << 3
} A128MetricAvailability;

typedef uint32_t A128LevelMask;
typedef uint32_t A128MetricMask;

enum {
    A128_LEVEL_MASK_L1 = 1u << A128_LEVEL_L1,
    A128_LEVEL_MASK_L2 = 1u << A128_LEVEL_L2,
    A128_LEVEL_MASK_L3 = 1u << A128_LEVEL_L3,
    A128_LEVEL_MASK_MEMORY = 1u << A128_LEVEL_MEMORY,
    A128_LEVEL_MASK_ALL = A128_LEVEL_MASK_L1 | A128_LEVEL_MASK_L2 |
        A128_LEVEL_MASK_L3 | A128_LEVEL_MASK_MEMORY,
    A128_METRIC_MASK_ALL = A128_METRIC_READ | A128_METRIC_WRITE |
        A128_METRIC_COPY | A128_METRIC_LATENCY
};

typedef enum A128ProgressPhase {
    A128_PROGRESS_STAGE_STARTED = 0,
    A128_PROGRESS_CALIBRATING = 1,
    A128_PROGRESS_SAMPLE_COMPLETED = 2,
    A128_PROGRESS_STAGE_COMPLETED = 3,
    A128_PROGRESS_RUN_COMPLETED = 4
} A128ProgressPhase;

typedef struct A128RunConfiguration {
    uint32_t struct_size;
    A128LevelMask level_mask;
    A128MetricMask metric_mask;
    uint32_t sample_count;
    uint32_t throughput_worker_count;
    uint64_t total_run_nanoseconds;
} A128RunConfiguration;

typedef struct A128Configuration {
    uint32_t sample_count;
    uint64_t minimum_sample_nanoseconds;
    uint32_t throughput_worker_count;
} A128Configuration;

typedef struct A128SystemInfo {
    char cpu_name[128];
    char architecture[16];
    char backend[32];
    char cpu_microarchitecture[48];
    char cpu_socket[32];
    char cpu_features[1024];
    char memory_type[32];
    char memory_manufacturer[64];
    char memory_part_number[96];
    char platform_name[64];
    char motherboard[128];
    char chipset[96];
    char firmware[128];
    uint64_t memory_bytes;
    uint64_t l1_data_bytes;
    uint64_t l2_bytes;
    uint64_t l3_bytes;
    uint32_t logical_cpu_count;
    uint32_t cpu_family;
    uint32_t cpu_model;
    uint32_t cpu_stepping;
    uint32_t cpu_signature;
    uint32_t microcode_version;
    uint32_t cpu_base_megahertz;
    uint32_t cpu_max_megahertz;
    uint32_t reference_clock_megahertz;
    uint32_t memory_data_rate;
    uint32_t memory_module_count;
} A128SystemInfo;

typedef struct A128Measurement {
    A128Level level;
    A128Scope scope;
    uint32_t available_metrics;
    uint64_t working_set_bytes;
    double read_gigabytes_per_second;
    double write_gigabytes_per_second;
    double copy_gigabytes_per_second;
    double latency_nanoseconds;
    double maximum_relative_spread;
} A128Measurement;

typedef struct A128ProgressEvent {
    uint32_t struct_size;
    A128ProgressPhase phase;
    A128Level level;
    uint32_t metric;
    uint32_t completed_stage_count;
    uint32_t total_stage_count;
    uint32_t completed_sample_count;
    uint32_t sample_count;
    A128Measurement measurement;
} A128ProgressEvent;

typedef void (*A128ProgressCallback)(void *context, const A128ProgressEvent *event);

typedef struct A128Report {
    A128SystemInfo system;
    A128Measurement measurements[8];
    uint32_t measurement_count;
    uint32_t throughput_worker_count;
} A128Report;

A128Configuration a128_default_configuration(void) A128_NOEXCEPT;
A128Status a128_read_system_info(A128SystemInfo *output) A128_NOEXCEPT;
A128Status a128_run_benchmark(const A128Configuration *configuration, A128Report *output) A128_NOEXCEPT;
A128Status a128_run_benchmark_v2(
    const A128RunConfiguration *configuration,
    A128ProgressCallback callback,
    void *context,
    A128Report *output
) A128_NOEXCEPT;
const char *a128_status_message(A128Status status) A128_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef A128_NOEXCEPT

#endif
