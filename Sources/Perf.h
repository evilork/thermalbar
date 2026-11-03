// Perf.h - GPU frequency, GPU load and CPU/GPU power from IOReport (no sudo, no helper).
#ifndef THERMALBAR_PERF_H
#define THERMALBAR_PERF_H

typedef struct {
    /// 1 when GPU residency was read for this interval.
    int gpuValid;
    /// Average GPU frequency while active, MHz.
    double gpuFreqMHz;
    /// Share of time the GPU was active, 0...1.
    double gpuActive;
    /// CPU and GPU power over the interval in watts, or -1 when unknown.
    double cpuPowerW;
    double gpuPowerW;
} TBPerfSample;

/// Subscribes to the IOReport channels. Returns 1 on success.
int tb_perf_open(void);

/// Returns the values for the time since the previous call (the first call has gpuValid = 0).
TBPerfSample tb_perf_sample(void);

/// Highest GPU frequency of this chip in MHz, or 0 when unknown.
double tb_perf_gpu_max_mhz(void);

/// Releases the subscription.
void tb_perf_close(void);

#endif
