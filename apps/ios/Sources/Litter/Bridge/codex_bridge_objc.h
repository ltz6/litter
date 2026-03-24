#import <Foundation/Foundation.h>
#include <stddef.h>
#include <stdint.h>

/// Create an AEC processor for the given sample rate (for example, 48000 Hz).
void * _Nullable aec_create(uint32_t sample_rate);

/// Destroy an AEC processor previously returned by aec_create().
void aec_destroy(void * _Nullable handle);

/// Return the expected frame size in samples (sample_rate / 100).
size_t aec_get_frame_size(const void * _Nullable handle);

/// Feed far-end playback audio to the AEC as mono f32 samples.
int aec_analyze_render(const void * _Nullable handle, const float * _Nonnull samples, size_t count);

/// Process far-end playback audio through the render path as mono f32 samples.
int aec_process_render(void * _Nullable handle, float * _Nonnull samples, size_t count);

/// Process microphone capture audio in place as mono f32 samples.
int aec_process_capture(void * _Nullable handle, float * _Nonnull samples, size_t count);

/// Initializes the ios_system environment and sandbox filesystem layout.
void codex_ios_system_init(void);

/// Returns the default working directory for local codex sessions (/home/codex inside sandbox).
/// Must be called after codex_ios_system_init().
NSString * _Nullable codex_ios_default_cwd(void);
