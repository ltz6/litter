use std::ffi::c_void;

#[unsafe(no_mangle)]
pub extern "C" fn aec_create(sample_rate: u32) -> *mut c_void {
    codex_ios_audio::aec_create(sample_rate)
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_destroy(handle: *mut c_void) {
    codex_ios_audio::aec_destroy(handle);
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_get_frame_size(handle: *const c_void) -> usize {
    codex_ios_audio::aec_get_frame_size(handle)
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_analyze_render(
    handle: *const c_void,
    samples: *const f32,
    count: usize,
) -> i32 {
    codex_ios_audio::aec_analyze_render(handle, samples, count)
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_process_render(handle: *mut c_void, samples: *mut f32, count: usize) -> i32 {
    codex_ios_audio::aec_process_render(handle, samples, count)
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_process_capture(handle: *mut c_void, samples: *mut f32, count: usize) -> i32 {
    codex_ios_audio::aec_process_capture(handle, samples, count)
}
