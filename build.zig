const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const t = target.result;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = "SDL2",
        .version = .{ .major = 2, .minor = 32, .patch = 10 },
        .linkage = if (t.abi.isAndroid()) .dynamic else .static,
        .root_module = mod,
    });

    const sdl_include_path = b.path("include");
    mod.addCSourceFiles(.{ .files = &generic_src_files });
    mod.addCMacro("SDL_USE_BUILTIN_OPENGL_DEFINITIONS", "1");
    mod.addCMacro("HAVE_GCC_ATOMICS", "1");
    mod.addCMacro("HAVE_GCC_SYNC_LOCK_TEST_AND_SET", "1");

    switch (t.os.tag) {
        .windows => {
            mod.addCMacro("SDL_STATIC_LIB", "");
            mod.addCSourceFiles(.{ .files = &windows_src_files });
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("shell32", .{});
            mod.linkSystemLibrary("advapi32", .{});
            mod.linkSystemLibrary("setupapi", .{});
            mod.linkSystemLibrary("winmm", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("imm32", .{});
            mod.linkSystemLibrary("version", .{});
            mod.linkSystemLibrary("oleaut32", .{});
            mod.linkSystemLibrary("ole32", .{});
        },
        .macos => {
            mod.addCSourceFiles(.{ .files = &darwin_src_files });
            mod.addCSourceFiles(.{
                .files = &objective_c_src_files,
                .flags = &.{"-fobjc-arc"},
            });
            mod.linkFramework("OpenGL", .{});
            mod.linkFramework("Metal", .{});
            mod.linkFramework("CoreVideo", .{});
            mod.linkFramework("Cocoa", .{});
            mod.linkFramework("IOKit", .{});
            mod.linkFramework("ForceFeedback", .{});
            mod.linkFramework("Carbon", .{});
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AudioToolbox", .{});
            mod.linkFramework("AVFoundation", .{});
            mod.linkFramework("Foundation", .{});
        },
        .emscripten => {
            mod.addCMacro("__EMSCRIPTEN_PTHREADS__", "1");
            mod.addCMacro("USE_SDL", "2");
            mod.addCSourceFiles(.{ .files = &emscripten_src_files });

            const sysroot = if (@hasField(std.Build, "sysroot"))
                b.sysroot orelse @panic("Pass '--sysroot \"$EMSDK/upstream/emscripten\"'")
            else
                @panic("`sysroot` was removed from the build system in newer versions of Zig"); // Help wanted

            const cache_include = std.fs.path.join(b.allocator, &.{ sysroot, "cache", "sysroot", "include" }) catch @panic("Out of memory");
            defer b.allocator.free(cache_include);

            // TODO: Remove compatibility shim when minimum Zig version is 0.16.0.
            if (@hasDecl(std.Io, "Dir")) {
                // Zig 0.16.0-dev
                var dir = std.Io.Dir.openDirAbsolute(mod.owner.graph.io, cache_include, .{
                    .access_sub_paths = true,
                    .follow_symlinks = false,
                }) catch @panic("No emscripten cache. Generate it!");
                dir.close(mod.owner.graph.io);
            } else if (@hasDecl(std.fs, "Dir")) {
                // Zig 0.15.x
                var dir = std.fs.openDirAbsolute(cache_include, .{
                    .access_sub_paths = true,
                    .no_follow = true,
                }) catch @panic("No emscripten cache. Generate it!");
                dir.close();
            } else @compileError("Fix `openDirAbsolute` compatibility shim");

            mod.addIncludePath(.{ .cwd_relative = cache_include });
        },
        else => {
            if (t.abi.isAndroid()) {
                mod.addCSourceFiles(.{
                    .files = &android_src_files,
                });

                // This is needed for "src/render/opengles/SDL_render_gles.c" to compile
                mod.addCMacro("GL_GLEXT_PROTOTYPES", "1");

                // Add Java files to dependency so that they can be copied downstream
                const java_dir = b.path("android-project/app/src/main/java/org/libsdl/app");
                const java_files: []const []const u8 = &.{
                    "SDL.java",
                    "SDLSurface.java",
                    "SDLActivity.java",
                    "SDLAudioManager.java",
                    "SDLControllerManager.java",
                    "HIDDevice.java",
                    "HIDDeviceUSB.java",
                    "HIDDeviceManager.java",
                    "HIDDeviceBLESteamController.java",
                };
                const java_write_files = b.addNamedWriteFiles("sdljava");
                for (java_files) |java_file_basename| {
                    _ = java_write_files.addCopyFile(java_dir.path(b, java_file_basename), java_file_basename);
                }

                // https://github.com/libsdl-org/SDL/blob/release-2.30.6/Android.mk#L82C62-L82C69
                mod.linkSystemLibrary("dl", .{});
                mod.linkSystemLibrary("GLESv1_CM", .{});
                mod.linkSystemLibrary("GLESv2", .{});
                mod.linkSystemLibrary("OpenSLES", .{});
                mod.linkSystemLibrary("log", .{});
                mod.linkSystemLibrary("android", .{});
            }
        },
    }

    mod.addIncludePath(sdl_include_path);

    const use_pregenerated_config = switch (t.os.tag) {
        .windows, .macos, .emscripten => true,
        .linux => t.abi.isAndroid(),
        else => false,
    };

    if (use_pregenerated_config) {
        mod.addIncludePath(b.path("include-pregen"));
        lib.installHeadersDirectory(b.path("include-pregen"), "SDL2", .{});
        mod.addCSourceFiles(.{ .files = render_driver_sw.src_files });
    } else {
        // causes pregenerated SDL_config.h to assert an error
        mod.addCMacro("USING_GENERATED_CONFIG_H", "");

        const config_header = configHeader(b, t);
        switch (t.os.tag) {
            .linux => {
                mod.addCSourceFiles(.{ .files = &linux_src_files });
                config_header.addValues(.{
                    .SDL_VIDEO_OPENGL = 1,
                    .SDL_VIDEO_OPENGL_ES = 1,
                    .SDL_VIDEO_OPENGL_ES2 = 1,
                    .SDL_VIDEO_OPENGL_BGL = 1,
                    .SDL_VIDEO_OPENGL_CGL = 1,
                    .SDL_VIDEO_OPENGL_GLX = 1,
                    .SDL_VIDEO_OPENGL_WGL = 1,
                    .SDL_VIDEO_OPENGL_EGL = 1,
                    .SDL_VIDEO_OPENGL_OSMESA = 1,
                    .SDL_VIDEO_OPENGL_OSMESA_DYNAMIC = 1,
                });
                applyOptions(b, mod, config_header, &linux_options);
            },
            else => {},
        }
        mod.addConfigHeader(config_header);
        lib.installHeader(config_header.getOutputFile(), "SDL2/SDL_config.h");

        const revision_header = b.addConfigHeader(.{
            .style = .{ .cmake = b.path("include/SDL_revision.h.cmake") },
            .include_path = "SDL_revision.h",
        }, .{
            .SDL_REVISION = b.fmt("SDL-{f}", .{lib.version.?}),
            .SDL_VENDOR_INFO = "allyourcodebase.com",
        });
        mod.addConfigHeader(revision_header);
        lib.installHeader(revision_header.getOutputFile(), "SDL2/SDL_revision.h");
    }

    const use_hidapi = b.option(bool, "use_hidapi", "Use hidapi shared library") orelse t.abi.isAndroid();

    if (use_hidapi) {
        const hidapi_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        const hidapi_lib = b.addLibrary(.{
            .name = "hidapi",
            .linkage = .dynamic,
            .root_module = hidapi_mod,
        });
        hidapi_mod.addIncludePath(sdl_include_path);
        hidapi_mod.addIncludePath(b.path("include-pregen"));
        hidapi_mod.addCSourceFiles(.{
            .root = b.path(""),
            .files = &[_][]const u8{
                "src/hidapi/android/hid.cpp",
            },
            .flags = &.{"-std=c++11"},
        });
        hidapi_mod.linkSystemLibrary("log", .{});
        mod.linkLibrary(hidapi_lib);
        b.installArtifact(hidapi_lib);
    }

    lib.installHeadersDirectory(b.path("include"), "SDL2", .{});
    b.installArtifact(lib);
}

const generic_src_files = [_][]const u8{
    "src/SDL.c",
    "src/SDL_assert.c",
    "src/SDL_dataqueue.c",
    "src/SDL_error.c",
    "src/SDL_guid.c",
    "src/SDL_hints.c",
    "src/SDL_list.c",
    "src/SDL_log.c",
    "src/SDL_utils.c",
    "src/atomic/SDL_atomic.c",
    "src/atomic/SDL_spinlock.c",
    "src/audio/SDL_audio.c",
    "src/audio/SDL_audiocvt.c",
    "src/audio/SDL_audiodev.c",
    "src/audio/SDL_audiotypecvt.c",
    "src/audio/SDL_mixer.c",
    "src/audio/SDL_wave.c",
    "src/cpuinfo/SDL_cpuinfo.c",
    "src/dynapi/SDL_dynapi.c",
    "src/events/SDL_clipboardevents.c",
    "src/events/SDL_displayevents.c",
    "src/events/SDL_dropevents.c",
    "src/events/SDL_events.c",
    "src/events/SDL_gesture.c",
    "src/events/SDL_keyboard.c",
    "src/events/SDL_keysym_to_scancode.c",
    "src/events/SDL_mouse.c",
    "src/events/SDL_quit.c",
    "src/events/SDL_scancode_tables.c",
    "src/events/SDL_touch.c",
    "src/events/SDL_windowevents.c",
    "src/events/imKStoUCS.c",
    "src/file/SDL_rwops.c",
    "src/haptic/SDL_haptic.c",
    "src/hidapi/SDL_hidapi.c",

    "src/joystick/SDL_gamecontroller.c",
    "src/joystick/SDL_joystick.c",
    "src/joystick/SDL_steam_virtual_gamepad.c",
    "src/joystick/controller_type.c",
    "src/joystick/virtual/SDL_virtualjoystick.c",

    "src/libm/e_atan2.c",
    "src/libm/e_exp.c",
    "src/libm/e_fmod.c",
    "src/libm/e_log.c",
    "src/libm/e_log10.c",
    "src/libm/e_pow.c",
    "src/libm/e_rem_pio2.c",
    "src/libm/e_sqrt.c",
    "src/libm/k_cos.c",
    "src/libm/k_rem_pio2.c",
    "src/libm/k_sin.c",
    "src/libm/k_tan.c",
    "src/libm/s_atan.c",
    "src/libm/s_copysign.c",
    "src/libm/s_cos.c",
    "src/libm/s_fabs.c",
    "src/libm/s_floor.c",
    "src/libm/s_scalbn.c",
    "src/libm/s_sin.c",
    "src/libm/s_tan.c",
    "src/locale/SDL_locale.c",
    "src/misc/SDL_url.c",
    "src/power/SDL_power.c",
    "src/render/SDL_d3dmath.c",
    "src/render/SDL_render.c",
    "src/render/SDL_yuv_sw.c",
    "src/sensor/SDL_sensor.c",
    "src/stdlib/SDL_crc16.c",
    "src/stdlib/SDL_crc32.c",
    "src/stdlib/SDL_getenv.c",
    "src/stdlib/SDL_iconv.c",
    "src/stdlib/SDL_malloc.c",
    "src/stdlib/SDL_mslibc.c",
    "src/stdlib/SDL_qsort.c",
    "src/stdlib/SDL_stdlib.c",
    "src/stdlib/SDL_string.c",
    "src/stdlib/SDL_strtokr.c",
    "src/thread/SDL_thread.c",
    "src/timer/SDL_timer.c",
    "src/video/SDL_RLEaccel.c",
    "src/video/SDL_blit.c",
    "src/video/SDL_blit_0.c",
    "src/video/SDL_blit_1.c",
    "src/video/SDL_blit_A.c",
    "src/video/SDL_blit_N.c",
    "src/video/SDL_blit_auto.c",
    "src/video/SDL_blit_copy.c",
    "src/video/SDL_blit_slow.c",
    "src/video/SDL_bmp.c",
    "src/video/SDL_clipboard.c",
    "src/video/SDL_egl.c",
    "src/video/SDL_fillrect.c",
    "src/video/SDL_pixels.c",
    "src/video/SDL_rect.c",
    "src/video/SDL_shape.c",
    "src/video/SDL_stretch.c",
    "src/video/SDL_surface.c",
    "src/video/SDL_video.c",
    "src/video/SDL_vulkan_utils.c",
    "src/video/SDL_yuv.c",
    "src/video/yuv2rgb/yuv_rgb_lsx.c",
    "src/video/yuv2rgb/yuv_rgb_sse.c",
    "src/video/yuv2rgb/yuv_rgb_std.c",

    "src/video/dummy/SDL_nullevents.c",
    "src/video/dummy/SDL_nullframebuffer.c",
    "src/video/dummy/SDL_nullvideo.c",

    "src/audio/dummy/SDL_dummyaudio.c",

    "src/joystick/hidapi/SDL_hidapi_combined.c",
    "src/joystick/hidapi/SDL_hidapi_gamecube.c",
    "src/joystick/hidapi/SDL_hidapi_luna.c",
    "src/joystick/hidapi/SDL_hidapi_ps3.c",
    "src/joystick/hidapi/SDL_hidapi_ps4.c",
    "src/joystick/hidapi/SDL_hidapi_ps5.c",
    "src/joystick/hidapi/SDL_hidapi_rumble.c",
    "src/joystick/hidapi/SDL_hidapi_shield.c",
    "src/joystick/hidapi/SDL_hidapi_stadia.c",
    "src/joystick/hidapi/SDL_hidapi_steam.c",
    "src/joystick/hidapi/SDL_hidapi_steamdeck.c",
    "src/joystick/hidapi/SDL_hidapi_switch.c",
    "src/joystick/hidapi/SDL_hidapi_wii.c",
    "src/joystick/hidapi/SDL_hidapi_xbox360.c",
    "src/joystick/hidapi/SDL_hidapi_xbox360w.c",
    "src/joystick/hidapi/SDL_hidapi_xboxone.c",
    "src/joystick/hidapi/SDL_hidapijoystick.c",
};

const android_src_files = [_][]const u8{
    "src/core/android/SDL_android.c",

    "src/audio/android/SDL_androidaudio.c",
    "src/audio/openslES/SDL_openslES.c",
    "src/audio/aaudio/SDL_aaudio.c",

    "src/haptic/android/SDL_syshaptic.c",
    "src/joystick/android/SDL_sysjoystick.c",
    "src/locale/android/SDL_syslocale.c",
    "src/misc/android/SDL_sysurl.c",
    "src/power/android/SDL_syspower.c",
    "src/filesystem/android/SDL_sysfilesystem.c",
    "src/sensor/android/SDL_androidsensor.c",

    "src/timer/unix/SDL_systimer.c",
    "src/loadso/dlopen/SDL_sysloadso.c",

    "src/thread/pthread/SDL_syscond.c",
    "src/thread/pthread/SDL_sysmutex.c",
    "src/thread/pthread/SDL_syssem.c",
    "src/thread/pthread/SDL_systhread.c",
    "src/thread/pthread/SDL_systls.c",
    "src/render/opengles/SDL_render_gles.c",
    "src/render/opengles2/SDL_render_gles2.c",
    "src/render/opengles2/SDL_shaders_gles2.c",

    "src/video/android/SDL_androidclipboard.c",
    "src/video/android/SDL_androidevents.c",
    "src/video/android/SDL_androidgl.c",
    "src/video/android/SDL_androidkeyboard.c",
    "src/video/android/SDL_androidmessagebox.c",
    "src/video/android/SDL_androidmouse.c",
    "src/video/android/SDL_androidtouch.c",
    "src/video/android/SDL_androidvideo.c",
    "src/video/android/SDL_androidvulkan.c",
    "src/video/android/SDL_androidwindow.c",
};

const windows_src_files = [_][]const u8{
    "src/core/windows/SDL_hid.c",
    "src/core/windows/SDL_immdevice.c",
    "src/core/windows/SDL_windows.c",
    "src/core/windows/SDL_xinput.c",
    "src/filesystem/windows/SDL_sysfilesystem.c",
    "src/haptic/windows/SDL_dinputhaptic.c",
    "src/haptic/windows/SDL_windowshaptic.c",
    "src/haptic/windows/SDL_xinputhaptic.c",
    "src/hidapi/windows/hid.c",
    "src/joystick/windows/SDL_dinputjoystick.c",
    "src/joystick/windows/SDL_rawinputjoystick.c",
    "src/joystick/windows/SDL_windows_gaming_input.c",
    "src/joystick/windows/SDL_windowsjoystick.c",
    "src/joystick/windows/SDL_xinputjoystick.c",

    "src/loadso/windows/SDL_sysloadso.c",
    "src/locale/windows/SDL_syslocale.c",
    "src/main/windows/SDL_windows_main.c",
    "src/misc/windows/SDL_sysurl.c",
    "src/power/windows/SDL_syspower.c",
    "src/sensor/windows/SDL_windowssensor.c",
    "src/timer/windows/SDL_systimer.c",
    "src/video/windows/SDL_windowsclipboard.c",
    "src/video/windows/SDL_windowsevents.c",
    "src/video/windows/SDL_windowsframebuffer.c",
    "src/video/windows/SDL_windowskeyboard.c",
    "src/video/windows/SDL_windowsmessagebox.c",
    "src/video/windows/SDL_windowsmodes.c",
    "src/video/windows/SDL_windowsmouse.c",
    "src/video/windows/SDL_windowsopengl.c",
    "src/video/windows/SDL_windowsopengles.c",
    "src/video/windows/SDL_windowsshape.c",
    "src/video/windows/SDL_windowsvideo.c",
    "src/video/windows/SDL_windowsvulkan.c",
    "src/video/windows/SDL_windowswindow.c",

    "src/thread/windows/SDL_syscond_cv.c",
    "src/thread/windows/SDL_sysmutex.c",
    "src/thread/windows/SDL_syssem.c",
    "src/thread/windows/SDL_systhread.c",
    "src/thread/windows/SDL_systls.c",
    "src/thread/generic/SDL_syscond.c",

    "src/render/direct3d/SDL_render_d3d.c",
    "src/render/direct3d/SDL_shaders_d3d.c",
    "src/render/direct3d11/SDL_render_d3d11.c",
    "src/render/direct3d11/SDL_shaders_d3d11.c",
    "src/render/direct3d12/SDL_render_d3d12.c",
    "src/render/direct3d12/SDL_shaders_d3d12.c",

    "src/audio/directsound/SDL_directsound.c",
    "src/audio/wasapi/SDL_wasapi.c",
    "src/audio/wasapi/SDL_wasapi_win32.c",
    "src/audio/winmm/SDL_winmm.c",
    "src/audio/disk/SDL_diskaudio.c",

    "src/render/opengl/SDL_render_gl.c",
    "src/render/opengl/SDL_shaders_gl.c",
    "src/render/opengles/SDL_render_gles.c",
    "src/render/opengles2/SDL_render_gles2.c",
    "src/render/opengles2/SDL_shaders_gles2.c",
};

const linux_src_files = [_][]const u8{
    "src/core/linux/SDL_evdev.c",
    "src/core/linux/SDL_evdev_capabilities.c",
    "src/core/linux/SDL_evdev_kbd.c",
    "src/core/linux/SDL_threadprio.c",
    "src/core/unix/SDL_poll.c",

    "src/filesystem/unix/SDL_sysfilesystem.c",

    "src/haptic/linux/SDL_syshaptic.c",

    "src/loadso/dlopen/SDL_sysloadso.c",
    "src/joystick/linux/SDL_sysjoystick.c",
    "src/joystick/steam/SDL_steamcontroller.c",

    "src/misc/unix/SDL_sysurl.c",

    "src/thread/pthread/SDL_sysmutex.c",
    "src/thread/pthread/SDL_syssem.c",
    "src/thread/pthread/SDL_systhread.c",
    "src/thread/pthread/SDL_systls.c",

    "src/timer/unix/SDL_systimer.c",

    "src/video/x11/SDL_x11clipboard.c",
    "src/video/x11/SDL_x11dyn.c",
    "src/video/x11/SDL_x11events.c",
    "src/video/x11/SDL_x11framebuffer.c",
    "src/video/x11/SDL_x11keyboard.c",
    "src/video/x11/SDL_x11messagebox.c",
    "src/video/x11/SDL_x11modes.c",
    "src/video/x11/SDL_x11mouse.c",
    "src/video/x11/SDL_x11opengl.c",
    "src/video/x11/SDL_x11opengles.c",
    "src/video/x11/SDL_x11shape.c",
    "src/video/x11/SDL_x11touch.c",
    "src/video/x11/SDL_x11video.c",
    "src/video/x11/SDL_x11vulkan.c",
    "src/video/x11/SDL_x11window.c",
    "src/video/x11/SDL_x11xfixes.c",
    "src/video/x11/SDL_x11xinput2.c",
    "src/video/x11/edid-parse.c",
};

const darwin_src_files = [_][]const u8{
    "src/haptic/darwin/SDL_syshaptic.c",
    "src/joystick/darwin/SDL_iokitjoystick.c",
    "src/power/macosx/SDL_syspower.c",
    "src/timer/unix/SDL_systimer.c",
    "src/loadso/dlopen/SDL_sysloadso.c",
    "src/audio/disk/SDL_diskaudio.c",
    "src/render/opengl/SDL_render_gl.c",
    "src/render/opengl/SDL_shaders_gl.c",
    "src/render/opengles/SDL_render_gles.c",
    "src/render/opengles2/SDL_render_gles2.c",
    "src/render/opengles2/SDL_shaders_gles2.c",
    "src/sensor/dummy/SDL_dummysensor.c",

    "src/thread/pthread/SDL_syscond.c",
    "src/thread/pthread/SDL_sysmutex.c",
    "src/thread/pthread/SDL_syssem.c",
    "src/thread/pthread/SDL_systhread.c",
    "src/thread/pthread/SDL_systls.c",
};

const objective_c_src_files = [_][]const u8{
    "src/audio/coreaudio/SDL_coreaudio.m",
    "src/file/cocoa/SDL_rwopsbundlesupport.m",
    "src/filesystem/cocoa/SDL_sysfilesystem.m",
    //"src/hidapi/testgui/mac_support_cocoa.m",
    // This appears to be for SDL3 only.
    //"src/joystick/apple/SDL_mfijoystick.m",
    "src/locale/macosx/SDL_syslocale.m",
    "src/misc/macosx/SDL_sysurl.m",
    "src/power/uikit/SDL_syspower.m",
    "src/render/metal/SDL_render_metal.m",
    "src/sensor/coremotion/SDL_coremotionsensor.m",
    "src/video/cocoa/SDL_cocoaclipboard.m",
    "src/video/cocoa/SDL_cocoaevents.m",
    "src/video/cocoa/SDL_cocoakeyboard.m",
    "src/video/cocoa/SDL_cocoamessagebox.m",
    "src/video/cocoa/SDL_cocoametalview.m",
    "src/video/cocoa/SDL_cocoamodes.m",
    "src/video/cocoa/SDL_cocoamouse.m",
    "src/video/cocoa/SDL_cocoaopengl.m",
    "src/video/cocoa/SDL_cocoaopengles.m",
    "src/video/cocoa/SDL_cocoashape.m",
    "src/video/cocoa/SDL_cocoavideo.m",
    "src/video/cocoa/SDL_cocoavulkan.m",
    "src/video/cocoa/SDL_cocoawindow.m",
    "src/video/uikit/SDL_uikitappdelegate.m",
    "src/video/uikit/SDL_uikitclipboard.m",
    "src/video/uikit/SDL_uikitevents.m",
    "src/video/uikit/SDL_uikitmessagebox.m",
    "src/video/uikit/SDL_uikitmetalview.m",
    "src/video/uikit/SDL_uikitmodes.m",
    "src/video/uikit/SDL_uikitopengles.m",
    "src/video/uikit/SDL_uikitopenglview.m",
    "src/video/uikit/SDL_uikitvideo.m",
    "src/video/uikit/SDL_uikitview.m",
    "src/video/uikit/SDL_uikitviewcontroller.m",
    "src/video/uikit/SDL_uikitvulkan.m",
    "src/video/uikit/SDL_uikitwindow.m",
};

const ios_src_files = [_][]const u8{
    "src/hidapi/ios/hid.m",
    "src/misc/ios/SDL_sysurl.m",
    "src/joystick/iphoneos/SDL_mfijoystick.m",
};

const emscripten_src_files = [_][]const u8{
    "src/audio/emscripten/SDL_emscriptenaudio.c",
    "src/filesystem/emscripten/SDL_sysfilesystem.c",
    "src/joystick/emscripten/SDL_sysjoystick.c",
    "src/locale/emscripten/SDL_syslocale.c",
    "src/misc/emscripten/SDL_sysurl.c",
    "src/power/emscripten/SDL_syspower.c",
    "src/video/emscripten/SDL_emscriptenevents.c",
    "src/video/emscripten/SDL_emscriptenframebuffer.c",
    "src/video/emscripten/SDL_emscriptenmouse.c",
    "src/video/emscripten/SDL_emscriptenopengles.c",
    "src/video/emscripten/SDL_emscriptenvideo.c",

    "src/timer/unix/SDL_systimer.c",
    "src/loadso/dlopen/SDL_sysloadso.c",
    "src/audio/disk/SDL_diskaudio.c",
    "src/render/opengles2/SDL_render_gles2.c",
    "src/render/opengles2/SDL_shaders_gles2.c",
    "src/sensor/dummy/SDL_dummysensor.c",

    "src/thread/pthread/SDL_syscond.c",
    "src/thread/pthread/SDL_sysmutex.c",
    "src/thread/pthread/SDL_syssem.c",
    "src/thread/pthread/SDL_systhread.c",
    "src/thread/pthread/SDL_systls.c",
};

const unknown_src_files = [_][]const u8{
    "src/thread/generic/SDL_syscond.c",
    "src/thread/generic/SDL_sysmutex.c",
    "src/thread/generic/SDL_syssem.c",
    "src/thread/generic/SDL_systhread.c",
    "src/thread/generic/SDL_systls.c",

    "src/audio/aaudio/SDL_aaudio.c",
    "src/audio/android/SDL_androidaudio.c",
    "src/audio/arts/SDL_artsaudio.c",
    "src/audio/dsp/SDL_dspaudio.c",
    "src/audio/esd/SDL_esdaudio.c",
    "src/audio/fusionsound/SDL_fsaudio.c",
    "src/audio/n3ds/SDL_n3dsaudio.c",
    "src/audio/nacl/SDL_naclaudio.c",
    "src/audio/nas/SDL_nasaudio.c",
    "src/audio/netbsd/SDL_netbsdaudio.c",
    "src/audio/openslES/SDL_openslES.c",
    "src/audio/os2/SDL_os2audio.c",
    "src/audio/paudio/SDL_paudio.c",
    "src/audio/pipewire/SDL_pipewire.c",
    "src/audio/ps2/SDL_ps2audio.c",
    "src/audio/psp/SDL_pspaudio.c",
    "src/audio/qsa/SDL_qsa_audio.c",
    "src/audio/sndio/SDL_sndioaudio.c",
    "src/audio/sun/SDL_sunaudio.c",
    "src/audio/vita/SDL_vitaaudio.c",

    "src/core/android/SDL_android.c",
    "src/core/freebsd/SDL_evdev_kbd_freebsd.c",
    "src/core/openbsd/SDL_wscons_kbd.c",
    "src/core/openbsd/SDL_wscons_mouse.c",
    "src/core/os2/SDL_os2.c",
    "src/core/os2/geniconv/geniconv.c",
    "src/core/os2/geniconv/os2cp.c",
    "src/core/os2/geniconv/os2iconv.c",
    "src/core/os2/geniconv/sys2utf8.c",
    "src/core/os2/geniconv/test.c",

    "src/file/n3ds/SDL_rwopsromfs.c",

    "src/filesystem/android/SDL_sysfilesystem.c",
    "src/filesystem/dummy/SDL_sysfilesystem.c",
    "src/filesystem/n3ds/SDL_sysfilesystem.c",
    "src/filesystem/nacl/SDL_sysfilesystem.c",
    "src/filesystem/os2/SDL_sysfilesystem.c",
    "src/filesystem/ps2/SDL_sysfilesystem.c",
    "src/filesystem/psp/SDL_sysfilesystem.c",
    "src/filesystem/riscos/SDL_sysfilesystem.c",
    "src/filesystem/unix/SDL_sysfilesystem.c",
    "src/filesystem/vita/SDL_sysfilesystem.c",

    "src/haptic/android/SDL_syshaptic.c",
    "src/haptic/dummy/SDL_syshaptic.c",

    "src/hidapi/libusb/hid.c",
    "src/hidapi/mac/hid.c",

    "src/joystick/android/SDL_sysjoystick.c",
    "src/joystick/bsd/SDL_bsdjoystick.c",
    "src/joystick/dummy/SDL_sysjoystick.c",
    "src/joystick/n3ds/SDL_sysjoystick.c",
    "src/joystick/os2/SDL_os2joystick.c",
    "src/joystick/ps2/SDL_sysjoystick.c",
    "src/joystick/psp/SDL_sysjoystick.c",
    "src/joystick/vita/SDL_sysjoystick.c",

    "src/loadso/dummy/SDL_sysloadso.c",
    "src/loadso/os2/SDL_sysloadso.c",

    "src/locale/android/SDL_syslocale.c",
    "src/locale/dummy/SDL_syslocale.c",
    "src/locale/n3ds/SDL_syslocale.c",
    "src/locale/unix/SDL_syslocale.c",
    "src/locale/vita/SDL_syslocale.c",
    "src/locale/winrt/SDL_syslocale.c",

    "src/main/android/SDL_android_main.c",
    "src/main/dummy/SDL_dummy_main.c",
    "src/main/gdk/SDL_gdk_main.c",
    "src/main/n3ds/SDL_n3ds_main.c",
    "src/main/nacl/SDL_nacl_main.c",
    "src/main/ps2/SDL_ps2_main.c",
    "src/main/psp/SDL_psp_main.c",
    "src/main/uikit/SDL_uikit_main.c",

    "src/misc/android/SDL_sysurl.c",
    "src/misc/dummy/SDL_sysurl.c",
    "src/misc/riscos/SDL_sysurl.c",
    "src/misc/unix/SDL_sysurl.c",
    "src/misc/vita/SDL_sysurl.c",

    "src/power/android/SDL_syspower.c",
    "src/power/haiku/SDL_syspower.c",
    "src/power/n3ds/SDL_syspower.c",
    "src/power/psp/SDL_syspower.c",
    "src/power/vita/SDL_syspower.c",

    "src/sensor/android/SDL_androidsensor.c",
    "src/sensor/n3ds/SDL_n3dssensor.c",
    "src/sensor/vita/SDL_vitasensor.c",

    "src/test/SDL_test_assert.c",
    "src/test/SDL_test_common.c",
    "src/test/SDL_test_compare.c",
    "src/test/SDL_test_crc32.c",
    "src/test/SDL_test_font.c",
    "src/test/SDL_test_fuzzer.c",
    "src/test/SDL_test_harness.c",
    "src/test/SDL_test_imageBlit.c",
    "src/test/SDL_test_imageBlitBlend.c",
    "src/test/SDL_test_imageFace.c",
    "src/test/SDL_test_imagePrimitives.c",
    "src/test/SDL_test_imagePrimitivesBlend.c",
    "src/test/SDL_test_log.c",
    "src/test/SDL_test_md5.c",
    "src/test/SDL_test_memory.c",
    "src/test/SDL_test_random.c",

    "src/thread/n3ds/SDL_sysmutex.c",
    "src/thread/n3ds/SDL_syssem.c",
    "src/thread/n3ds/SDL_systhread.c",
    "src/thread/os2/SDL_sysmutex.c",
    "src/thread/os2/SDL_syssem.c",
    "src/thread/os2/SDL_systhread.c",
    "src/thread/os2/SDL_systls.c",
    "src/thread/ps2/SDL_syssem.c",
    "src/thread/ps2/SDL_systhread.c",
    "src/thread/psp/SDL_sysmutex.c",
    "src/thread/psp/SDL_syssem.c",
    "src/thread/psp/SDL_systhread.c",
    "src/thread/vita/SDL_sysmutex.c",
    "src/thread/vita/SDL_syssem.c",
    "src/thread/vita/SDL_systhread.c",

    "src/timer/dummy/SDL_systimer.c",
    "src/timer/haiku/SDL_systimer.c",
    "src/timer/n3ds/SDL_systimer.c",
    "src/timer/os2/SDL_systimer.c",
    "src/timer/ps2/SDL_systimer.c",
    "src/timer/psp/SDL_systimer.c",
    "src/timer/vita/SDL_systimer.c",

    "src/video/android/SDL_androidclipboard.c",
    "src/video/android/SDL_androidevents.c",
    "src/video/android/SDL_androidgl.c",
    "src/video/android/SDL_androidkeyboard.c",
    "src/video/android/SDL_androidmessagebox.c",
    "src/video/android/SDL_androidmouse.c",
    "src/video/android/SDL_androidtouch.c",
    "src/video/android/SDL_androidvideo.c",
    "src/video/android/SDL_androidvulkan.c",
    "src/video/android/SDL_androidwindow.c",
    "src/video/directfb/SDL_DirectFB_WM.c",
    "src/video/directfb/SDL_DirectFB_dyn.c",
    "src/video/directfb/SDL_DirectFB_events.c",
    "src/video/directfb/SDL_DirectFB_modes.c",
    "src/video/directfb/SDL_DirectFB_mouse.c",
    "src/video/directfb/SDL_DirectFB_opengl.c",
    "src/video/directfb/SDL_DirectFB_render.c",
    "src/video/directfb/SDL_DirectFB_shape.c",
    "src/video/directfb/SDL_DirectFB_video.c",
    "src/video/directfb/SDL_DirectFB_vulkan.c",
    "src/video/directfb/SDL_DirectFB_window.c",
    "src/video/kmsdrm/SDL_kmsdrmdyn.c",
    "src/video/kmsdrm/SDL_kmsdrmevents.c",
    "src/video/kmsdrm/SDL_kmsdrmmouse.c",
    "src/video/kmsdrm/SDL_kmsdrmopengles.c",
    "src/video/kmsdrm/SDL_kmsdrmvideo.c",
    "src/video/kmsdrm/SDL_kmsdrmvulkan.c",
    "src/video/n3ds/SDL_n3dsevents.c",
    "src/video/n3ds/SDL_n3dsframebuffer.c",
    "src/video/n3ds/SDL_n3dsswkb.c",
    "src/video/n3ds/SDL_n3dstouch.c",
    "src/video/n3ds/SDL_n3dsvideo.c",
    "src/video/nacl/SDL_naclevents.c",
    "src/video/nacl/SDL_naclglue.c",
    "src/video/nacl/SDL_naclopengles.c",
    "src/video/nacl/SDL_naclvideo.c",
    "src/video/nacl/SDL_naclwindow.c",
    "src/video/offscreen/SDL_offscreenevents.c",
    "src/video/offscreen/SDL_offscreenframebuffer.c",
    "src/video/offscreen/SDL_offscreenopengles.c",
    "src/video/offscreen/SDL_offscreenvideo.c",
    "src/video/offscreen/SDL_offscreenwindow.c",
    "src/video/os2/SDL_os2dive.c",
    "src/video/os2/SDL_os2messagebox.c",
    "src/video/os2/SDL_os2mouse.c",
    "src/video/os2/SDL_os2util.c",
    "src/video/os2/SDL_os2video.c",
    "src/video/os2/SDL_os2vman.c",
    "src/video/pandora/SDL_pandora.c",
    "src/video/pandora/SDL_pandora_events.c",
    "src/video/ps2/SDL_ps2video.c",
    "src/video/psp/SDL_pspevents.c",
    "src/video/psp/SDL_pspgl.c",
    "src/video/psp/SDL_pspmouse.c",
    "src/video/psp/SDL_pspvideo.c",
    "src/video/qnx/gl.c",
    "src/video/qnx/keyboard.c",
    "src/video/qnx/video.c",
    "src/video/raspberry/SDL_rpievents.c",
    "src/video/raspberry/SDL_rpimouse.c",
    "src/video/raspberry/SDL_rpiopengles.c",
    "src/video/raspberry/SDL_rpivideo.c",
    "src/video/riscos/SDL_riscosevents.c",
    "src/video/riscos/SDL_riscosframebuffer.c",
    "src/video/riscos/SDL_riscosmessagebox.c",
    "src/video/riscos/SDL_riscosmodes.c",
    "src/video/riscos/SDL_riscosmouse.c",
    "src/video/riscos/SDL_riscosvideo.c",
    "src/video/riscos/SDL_riscoswindow.c",
    "src/video/vita/SDL_vitaframebuffer.c",
    "src/video/vita/SDL_vitagl_pvr.c",
    "src/video/vita/SDL_vitagles.c",
    "src/video/vita/SDL_vitagles_pvr.c",
    "src/video/vita/SDL_vitakeyboard.c",
    "src/video/vita/SDL_vitamessagebox.c",
    "src/video/vita/SDL_vitamouse.c",
    "src/video/vita/SDL_vitatouch.c",
    "src/video/vita/SDL_vitavideo.c",
    "src/video/vivante/SDL_vivanteopengles.c",
    "src/video/vivante/SDL_vivanteplatform.c",
    "src/video/vivante/SDL_vivantevideo.c",
    "src/video/vivante/SDL_vivantevulkan.c",

    "src/render/opengl/SDL_render_gl.c",
    "src/render/opengl/SDL_shaders_gl.c",
    "src/render/opengles/SDL_render_gles.c",
    "src/render/opengles2/SDL_render_gles2.c",
    "src/render/opengles2/SDL_shaders_gles2.c",
    "src/render/ps2/SDL_render_ps2.c",
    "src/render/psp/SDL_render_psp.c",
    "src/render/vitagxm/SDL_render_vita_gxm.c",
    "src/render/vitagxm/SDL_render_vita_gxm_memory.c",
    "src/render/vitagxm/SDL_render_vita_gxm_tools.c",
};

const static_headers = [_][]const u8{
    "begin_code.h",
    "close_code.h",
    "SDL_assert.h",
    "SDL_atomic.h",
    "SDL_audio.h",
    "SDL_bits.h",
    "SDL_blendmode.h",
    "SDL_clipboard.h",
    "SDL_config_android.h",
    "SDL_config_emscripten.h",
    "SDL_config_iphoneos.h",
    "SDL_config_macosx.h",
    "SDL_config_minimal.h",
    "SDL_config_ngage.h",
    "SDL_config_os2.h",
    "SDL_config_pandora.h",
    "SDL_config_windows.h",
    "SDL_config_wingdk.h",
    "SDL_config_winrt.h",
    "SDL_config_xbox.h",
    "SDL_copying.h",
    "SDL_cpuinfo.h",
    "SDL_egl.h",
    "SDL_endian.h",
    "SDL_error.h",
    "SDL_events.h",
    "SDL_filesystem.h",
    "SDL_gamecontroller.h",
    "SDL_gesture.h",
    "SDL_guid.h",
    "SDL.h",
    "SDL_haptic.h",
    "SDL_hidapi.h",
    "SDL_hints.h",
    "SDL_joystick.h",
    "SDL_keyboard.h",
    "SDL_keycode.h",
    "SDL_loadso.h",
    "SDL_locale.h",
    "SDL_log.h",
    "SDL_main.h",
    "SDL_messagebox.h",
    "SDL_metal.h",
    "SDL_misc.h",
    "SDL_mouse.h",
    "SDL_mutex.h",
    "SDL_name.h",
    "SDL_opengles2_gl2ext.h",
    "SDL_opengles2_gl2.h",
    "SDL_opengles2_gl2platform.h",
    "SDL_opengles2.h",
    "SDL_opengles2_khrplatform.h",
    "SDL_opengles.h",
    "SDL_opengl_glext.h",
    "SDL_opengl.h",
    "SDL_pixels.h",
    "SDL_platform.h",
    "SDL_power.h",
    "SDL_quit.h",
    "SDL_rect.h",
    "SDL_render.h",
    "SDL_rwops.h",
    "SDL_scancode.h",
    "SDL_sensor.h",
    "SDL_shape.h",
    "SDL_stdinc.h",
    "SDL_surface.h",
    "SDL_system.h",
    "SDL_syswm.h",
    "SDL_test_assert.h",
    "SDL_test_common.h",
    "SDL_test_compare.h",
    "SDL_test_crc32.h",
    "SDL_test_font.h",
    "SDL_test_fuzzer.h",
    "SDL_test.h",
    "SDL_test_harness.h",
    "SDL_test_images.h",
    "SDL_test_log.h",
    "SDL_test_md5.h",
    "SDL_test_memory.h",
    "SDL_test_random.h",
    "SDL_thread.h",
    "SDL_timer.h",
    "SDL_touch.h",
    "SDL_types.h",
    "SDL_version.h",
    "SDL_video.h",
    "SDL_vulkan.h",
};

const SdlOption = struct {
    name: []const u8,
    desc: []const u8,
    default: bool,
    // SDL configs affect the public SDL_config.h header file. Any values
    // should occur in a header file in the include directory.
    sdl_configs: []const []const u8,
    // C Macros are similar to SDL configs but aren't present in the public
    // headers and only affect the SDL implementation.  None of the values
    // should occur in the include directory.
    c_macros: []const []const u8 = &.{},
    src_files: []const []const u8,
    system_libs: []const []const u8,
};
const render_driver_sw = SdlOption{
    .name = "render_driver_software",
    .desc = "enable the software render driver",
    .default = true,
    .sdl_configs = &.{},
    .c_macros = &.{"SDL_VIDEO_RENDER_SW"},
    .src_files = &.{
        "src/render/software/SDL_blendfillrect.c",
        "src/render/software/SDL_blendline.c",
        "src/render/software/SDL_blendpoint.c",
        "src/render/software/SDL_drawline.c",
        "src/render/software/SDL_drawpoint.c",
        "src/render/software/SDL_render_sw.c",
        "src/render/software/SDL_rotate.c",
        "src/render/software/SDL_triangle.c",
    },
    .system_libs = &.{},
};
const linux_options = [_]SdlOption{
    render_driver_sw,
    .{
        .name = "video_driver_x11",
        .desc = "enable the x11 video driver",
        .default = true,
        .sdl_configs = &.{
            "SDL_VIDEO_DRIVER_X11",
            "SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS",
        },
        .src_files = &.{},
        .system_libs = &.{ "X11", "Xext" },
    },
    .{
        .name = "render_driver_ogl",
        .desc = "enable the opengl render driver",
        .default = true,
        .sdl_configs = &.{"SDL_VIDEO_RENDER_OGL"},
        .src_files = &.{
            "src/render/opengl/SDL_render_gl.c",
            "src/render/opengl/SDL_shaders_gl.c",
        },
        .system_libs = &.{},
    },
    .{
        .name = "render_driver_ogl_es",
        .desc = "enable the opengl es render driver",
        .default = true,
        .sdl_configs = &.{"SDL_VIDEO_RENDER_OGL_ES"},
        .src_files = &.{
            "src/render/opengles/SDL_render_gles.c",
        },
        .system_libs = &.{},
    },
    .{
        .name = "render_driver_ogl_es2",
        .desc = "enable the opengl es2 render driver",
        .default = true,
        .sdl_configs = &.{"SDL_VIDEO_RENDER_OGL_ES2"},
        .src_files = &.{
            "src/render/opengles2/SDL_render_gles2.c",
            "src/render/opengles2/SDL_shaders_gles2.c",
        },
        .system_libs = &.{},
    },
    .{
        .name = "audio_driver_pulse",
        .desc = "enable the pulse audio driver",
        .default = true,
        .sdl_configs = &.{"SDL_AUDIO_DRIVER_PULSEAUDIO"},
        .src_files = &.{"src/audio/pulseaudio/SDL_pulseaudio.c"},
        .system_libs = &.{"pulse"},
    },
    .{
        .name = "audio_driver_alsa",
        .desc = "enable the alsa audio driver",
        .default = false,
        .sdl_configs = &.{"SDL_AUDIO_DRIVER_ALSA"},
        .src_files = &.{"src/audio/alsa/SDL_alsa_audio.c"},
        .system_libs = &.{"alsa"},
    },
};

fn applyOptions(
    b: *std.Build,
    mod: *std.Build.Module,
    config_header: *std.Build.Step.ConfigHeader,
    comptime options: []const SdlOption,
) void {
    inline for (options) |option| {
        const enabled = if (b.option(bool, option.name, option.desc)) |o| o else option.default;
        for (option.c_macros) |name| {
            mod.addCMacro(name, if (enabled) "1" else "0");
        }
        for (option.sdl_configs) |config| {
            config_header.addValue(config, u1, @intFromBool(enabled));
        }
        if (enabled) {
            mod.addCSourceFiles(.{ .files = option.src_files });
            for (option.system_libs) |lib_name| {
                mod.linkSystemLibrary(lib_name, .{});
            }
        }
    }
}

fn configHeader(b: *std.Build, t: std.Target) *std.Build.Step.ConfigHeader {
    const is_linux = t.os.tag == .linux;
    const is_unix = t.os.tag != .windows;
    const is_musl = t.isMuslLibC();

    return b.addConfigHeader(.{
        .style = .{ .cmake = b.path("include/SDL_config.h.cmake") },
        .include_path = "SDL_config.h",
    }, .{
        // SDL_config.h.cmake values and comments with ordering and grouping preserved:

        .HAVE_CONST = 1,
        .HAVE_INLINE = 1,
        .HAVE_VOLATILE = 1,

        .HAVE_GCC_ATOMICS = 0,
        .HAVE_GCC_SYNC_LOCK_TEST_AND_SET = 0,

        // Comment this if you want to build without any C library requirements
        .HAVE_LIBC = 1,

        // Useful headers
        .STDC_HEADERS = 1,
        .HAVE_ALLOCA_H = 1,
        .HAVE_CTYPE_H = 1,
        .HAVE_FLOAT_H = 1,
        .HAVE_ICONV_H = 1,
        .HAVE_INTTYPES_H = 1,
        .HAVE_LIMITS_H = 1,
        .HAVE_MALLOC_H = 1,
        .HAVE_MATH_H = 1,
        .HAVE_MEMORY_H = 1,
        .HAVE_SIGNAL_H = 1,
        .HAVE_STDARG_H = 1,
        .HAVE_STDDEF_H = 1,
        .HAVE_STDINT_H = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRINGS_H = 1,
        .HAVE_STRING_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_WCHAR_H = 1,
        .HAVE_LINUX_INPUT_H = is_linux,
        .HAVE_PTHREAD_NP_H = 0,
        .HAVE_LIBUNWIND_H = 1,

        // C library functions
        .HAVE_DLOPEN = 1,
        .HAVE_MALLOC = 1,
        .HAVE_CALLOC = 1,
        .HAVE_REALLOC = 1,
        .HAVE_FREE = 1,
        .HAVE_ALLOCA = 1,

        // Don't use C runtime versions of these on Windows
        .HAVE_GETENV = 1,
        .HAVE_SETENV = 1,
        .HAVE_PUTENV = 1,
        .HAVE_UNSETENV = 1,

        .HAVE_QSORT = 1,
        .HAVE_BSEARCH = 1,
        .HAVE_ABS = 1,
        .HAVE_BCOPY = 1,
        .HAVE_MEMSET = 1,
        .HAVE_MEMCPY = 1,
        .HAVE_MEMMOVE = 1,
        .HAVE_MEMCMP = 1,
        .HAVE_WCSLEN = 1,
        .HAVE_WCSLCPY = !is_linux,
        .HAVE_WCSLCAT = !is_linux,
        .HAVE__WCSDUP = 0,
        .HAVE_WCSDUP = 1,
        .HAVE_WCSSTR = 1,
        .HAVE_WCSCMP = 1,
        .HAVE_WCSNCMP = 1,
        .HAVE_WCSCASECMP = 1,
        .HAVE__WCSICMP = 0,
        .HAVE_WCSNCASECMP = 1,
        .HAVE__WCSNICMP = 0,
        .HAVE_STRLEN = 1,
        .HAVE_STRLCPY = !is_linux or is_musl,
        .HAVE_STRLCAT = !is_linux or is_musl,
        .HAVE__STRREV = 0,
        .HAVE__STRUPR = 0,
        .HAVE__STRLWR = 0,
        .HAVE_INDEX = 1,
        .HAVE_RINDEX = 1,
        .HAVE_STRCHR = 1,
        .HAVE_STRRCHR = 1,
        .HAVE_STRSTR = 1,
        .HAVE_STRTOK_R = 1,
        .HAVE_ITOA = 0,
        .HAVE__LTOA = 0,
        .HAVE__UITOA = 0,
        .HAVE__ULTOA = 0,
        .HAVE_STRTOL = 1,
        .HAVE_STRTOUL = 1,
        .HAVE__I64TOA = 0,
        .HAVE__UI64TOA = 0,
        .HAVE_STRTOLL = 1,
        .HAVE_STRTOULL = 1,
        .HAVE_STRTOD = 1,
        .HAVE_ATOI = 1,
        .HAVE_ATOF = 1,
        .HAVE_STRCMP = 1,
        .HAVE_STRNCMP = 1,
        .HAVE__STRICMP = 0,
        .HAVE_STRCASECMP = 1,
        .HAVE__STRNICMP = 0,
        .HAVE_STRNCASECMP = 1,
        .HAVE_STRCASESTR = 1,
        .HAVE_SSCANF = 1,
        .HAVE_VSSCANF = 1,
        .HAVE_VSNPRINTF = 1,
        .HAVE_M_PI = 1,
        .HAVE_ACOS = 1,
        .HAVE_ACOSF = 1,
        .HAVE_ASIN = 1,
        .HAVE_ASINF = 1,
        .HAVE_ATAN = 1,
        .HAVE_ATANF = 1,
        .HAVE_ATAN2 = 1,
        .HAVE_ATAN2F = 1,
        .HAVE_CEIL = 1,
        .HAVE_CEILF = 1,
        .HAVE_COPYSIGN = 1,
        .HAVE_COPYSIGNF = 1,
        .HAVE_COS = 1,
        .HAVE_COSF = 1,
        .HAVE_EXP = 1,
        .HAVE_EXPF = 1,
        .HAVE_FABS = 1,
        .HAVE_FABSF = 1,
        .HAVE_FLOOR = 1,
        .HAVE_FLOORF = 1,
        .HAVE_FMOD = 1,
        .HAVE_FMODF = 1,
        .HAVE_LOG = 1,
        .HAVE_LOGF = 1,
        .HAVE_LOG10 = 1,
        .HAVE_LOG10F = 1,
        .HAVE_LROUND = 1,
        .HAVE_LROUNDF = 1,
        .HAVE_POW = 1,
        .HAVE_POWF = 1,
        .HAVE_ROUND = 1,
        .HAVE_ROUNDF = 1,
        .HAVE_SCALBN = 1,
        .HAVE_SCALBNF = 1,
        .HAVE_SIN = 1,
        .HAVE_SINF = 1,
        .HAVE_SQRT = 1,
        .HAVE_SQRTF = 1,
        .HAVE_TAN = 1,
        .HAVE_TANF = 1,
        .HAVE_TRUNC = 1,
        .HAVE_TRUNCF = 1,
        .HAVE_FOPEN64 = 1,
        .HAVE_FSEEKO = 1,
        .HAVE_FSEEKO64 = 1,
        .HAVE_MEMFD_CREATE = 1,
        .HAVE_POSIX_FALLOCATE = 1,
        .HAVE_SIGACTION = 1,
        .HAVE_SA_SIGACTION = 1,
        .HAVE_SETJMP = 1,
        .HAVE_NANOSLEEP = 1,
        .HAVE_SYSCONF = 1,
        .HAVE_SYSCTLBYNAME = t.os.tag.isDarwin(),
        .HAVE_CLOCK_GETTIME = 1,
        .HAVE_GETPAGESIZE = 1,
        .HAVE_MPROTECT = 1,
        .HAVE_ICONV = 1,
        .SDL_USE_LIBICONV = 1,
        .HAVE_PTHREAD_SETNAME_NP = 0,
        .HAVE_PTHREAD_SET_NAME_NP = 0,
        .HAVE_SEM_TIMEDWAIT = 1,
        .HAVE_GETAUXVAL = 1,
        .HAVE_ELF_AUX_INFO = 1,
        .HAVE_POLL = 1,
        .HAVE__EXIT = 0,

        .HAVE_ALTIVEC_H = 0,
        .HAVE_DBUS_DBUS_H = 0,
        .HAVE_FCITX = 0,
        .HAVE_IBUS_IBUS_H = 0,
        .HAVE_SYS_INOTIFY_H = is_linux,
        .HAVE_INOTIFY_INIT = is_linux,
        .HAVE_INOTIFY_INIT1 = is_linux,
        .HAVE_INOTIFY = is_linux,
        .HAVE_LIBUSB = 0,
        .HAVE_O_CLOEXEC = 0,

        // Apple platforms might be building universal binaries, where Intel builds
        // can use immintrin.h but other architectures can't.
        // Non-Apple platforms can use the normal CMake check for this.
        .HAVE_IMMINTRIN_H = t.cpu.arch.isX86(),

        .HAVE_LIBUDEV_H = 0,
        .HAVE_LIBSAMPLERATE_H = 0,
        .HAVE_LIBDECOR_H = 0,

        .HAVE_D3D_H = 0,
        .HAVE_D3D11_H = 0,
        .HAVE_D3D12_H = 0,
        .HAVE_DDRAW_H = 0,
        .HAVE_DSOUND_H = 0,
        .HAVE_DINPUT_H = 0,
        .HAVE_XINPUT_H = 0,
        .HAVE_WINDOWS_GAMING_INPUT_H = 0,
        .HAVE_DXGI_H = 0,

        .HAVE_MMDEVICEAPI_H = 0,
        .HAVE_AUDIOCLIENT_H = 0,
        .HAVE_TPCSHRD_H = 0,
        .HAVE_SENSORSAPI_H = 0,
        .HAVE_ROAPI_H = 0,
        .HAVE_SHELLSCALINGAPI_H = 0,

        .USE_POSIX_SPAWN = 0,

        // SDL internal assertion support
        .SDL_DEFAULT_ASSERT_LEVEL_CONFIGURED = 0,
        .SDL_DEFAULT_ASSERT_LEVEL = .undef,

        // Allow disabling of core subsystems
        .SDL_ATOMIC_DISABLED = 0,
        .SDL_AUDIO_DISABLED = 0,
        .SDL_CPUINFO_DISABLED = 0,
        .SDL_EVENTS_DISABLED = 0,
        .SDL_FILE_DISABLED = 0,
        .SDL_JOYSTICK_DISABLED = 0,
        .SDL_HAPTIC_DISABLED = 0,
        .SDL_HIDAPI_DISABLED = 0,
        .SDL_SENSOR_DISABLED = 0,
        .SDL_LOADSO_DISABLED = 0,
        .SDL_RENDER_DISABLED = 0,
        .SDL_THREADS_DISABLED = 0,
        .SDL_TIMERS_DISABLED = 0,
        .SDL_VIDEO_DISABLED = 0,
        .SDL_POWER_DISABLED = 0,
        .SDL_FILESYSTEM_DISABLED = 0,
        .SDL_LOCALE_DISABLED = 0,
        .SDL_MISC_DISABLED = 0,

        // Enable various audio drivers
        .SDL_AUDIO_DRIVER_ALSA = 0,
        .SDL_AUDIO_DRIVER_ALSA_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_ANDROID = 0,
        .SDL_AUDIO_DRIVER_OPENSLES = 0,
        .SDL_AUDIO_DRIVER_AAUDIO = 0,
        .SDL_AUDIO_DRIVER_ARTS = 0,
        .SDL_AUDIO_DRIVER_ARTS_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_COREAUDIO = 0,
        .SDL_AUDIO_DRIVER_DISK = 0,
        .SDL_AUDIO_DRIVER_DSOUND = 0,
        .SDL_AUDIO_DRIVER_DUMMY = 0,
        .SDL_AUDIO_DRIVER_EMSCRIPTEN = 0,
        .SDL_AUDIO_DRIVER_ESD = 0,
        .SDL_AUDIO_DRIVER_ESD_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_FUSIONSOUND = 0,
        .SDL_AUDIO_DRIVER_FUSIONSOUND_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_HAIKU = 0,
        .SDL_AUDIO_DRIVER_JACK = 0,
        .SDL_AUDIO_DRIVER_JACK_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_NAS = 0,
        .SDL_AUDIO_DRIVER_NAS_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_NETBSD = 0,
        .SDL_AUDIO_DRIVER_OSS = 0,
        .SDL_AUDIO_DRIVER_PAUDIO = 0,
        .SDL_AUDIO_DRIVER_PIPEWIRE = 0,
        .SDL_AUDIO_DRIVER_PIPEWIRE_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_PULSEAUDIO = 0,
        .SDL_AUDIO_DRIVER_PULSEAUDIO_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_QSA = 0,
        .SDL_AUDIO_DRIVER_SNDIO = 0,
        .SDL_AUDIO_DRIVER_SNDIO_DYNAMIC = 0,
        .SDL_AUDIO_DRIVER_SUNAUDIO = 0,
        .SDL_AUDIO_DRIVER_WASAPI = 0,
        .SDL_AUDIO_DRIVER_WINMM = 0,
        .SDL_AUDIO_DRIVER_OS2 = 0,
        .SDL_AUDIO_DRIVER_VITA = 0,
        .SDL_AUDIO_DRIVER_PSP = 0,
        .SDL_AUDIO_DRIVER_PS2 = 0,
        .SDL_AUDIO_DRIVER_N3DS = 0,

        // Enable various input drivers
        .SDL_INPUT_LINUXEV = is_linux,
        .SDL_INPUT_LINUXKD = is_linux,
        .SDL_INPUT_FBSDKBIO = 0,
        .SDL_INPUT_WSCONS = 0,
        .SDL_JOYSTICK_ANDROID = 0,
        .SDL_JOYSTICK_HAIKU = 0,
        .SDL_JOYSTICK_WGI = 0,
        .SDL_JOYSTICK_DINPUT = 0,
        .SDL_JOYSTICK_XINPUT = 0,
        .SDL_JOYSTICK_DUMMY = 0,
        .SDL_JOYSTICK_IOKIT = 0,
        .SDL_JOYSTICK_MFI = 0,
        .SDL_JOYSTICK_LINUX = is_linux,
        .SDL_JOYSTICK_OS2 = 0,
        .SDL_JOYSTICK_USBHID = 0,
        .SDL_HAVE_MACHINE_JOYSTICK_H = 0,
        .SDL_JOYSTICK_HIDAPI = 0,
        .SDL_JOYSTICK_RAWINPUT = 0,
        .SDL_JOYSTICK_EMSCRIPTEN = 0,
        .SDL_JOYSTICK_VIRTUAL = 0,
        .SDL_JOYSTICK_VITA = 0,
        .SDL_JOYSTICK_PSP = 0,
        .SDL_JOYSTICK_PS2 = 0,
        .SDL_JOYSTICK_N3DS = 0,
        .SDL_HAPTIC_DUMMY = 0,
        .SDL_HAPTIC_LINUX = is_linux,
        .SDL_HAPTIC_IOKIT = 0,
        .SDL_HAPTIC_DINPUT = 0,
        .SDL_HAPTIC_XINPUT = 0,
        .SDL_HAPTIC_ANDROID = 0,
        .SDL_LIBUSB_DYNAMIC = 0,
        .SDL_UDEV_DYNAMIC = 0,

        // Enable various sensor drivers
        .SDL_SENSOR_ANDROID = 0,
        .SDL_SENSOR_COREMOTION = 0,
        .SDL_SENSOR_WINDOWS = 0,
        .SDL_SENSOR_DUMMY = 0,
        .SDL_SENSOR_VITA = 0,
        .SDL_SENSOR_N3DS = 0,

        // Enable various shared object loading systems
        .SDL_LOADSO_DLOPEN = is_unix,
        .SDL_LOADSO_DUMMY = 0,
        .SDL_LOADSO_LDG = 0,
        .SDL_LOADSO_WINDOWS = 0,
        .SDL_LOADSO_OS2 = 0,

        // Enable various threading systems
        .SDL_THREAD_GENERIC_COND_SUFFIX = 0,
        .SDL_THREAD_PTHREAD = is_unix,
        .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX = is_unix,
        .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX_NP = 0,
        .SDL_THREAD_WINDOWS = 0,
        .SDL_THREAD_OS2 = 0,
        .SDL_THREAD_VITA = 0,
        .SDL_THREAD_PSP = 0,
        .SDL_THREAD_PS2 = 0,
        .SDL_THREAD_N3DS = 0,

        // Enable various timer systems
        .SDL_TIMER_HAIKU = 0,
        .SDL_TIMER_DUMMY = 0,
        .SDL_TIMER_UNIX = is_unix,
        .SDL_TIMER_WINDOWS = 0,
        .SDL_TIMER_OS2 = 0,
        .SDL_TIMER_VITA = 0,
        .SDL_TIMER_PSP = 0,
        .SDL_TIMER_PS2 = 0,
        .SDL_TIMER_N3DS = 0,

        // Enable various video drivers
        .SDL_VIDEO_DRIVER_ANDROID = 0,
        .SDL_VIDEO_DRIVER_EMSCRIPTEN = 0,
        .SDL_VIDEO_DRIVER_HAIKU = 0,
        .SDL_VIDEO_DRIVER_COCOA = 0,
        .SDL_VIDEO_DRIVER_UIKIT = 0,
        .SDL_VIDEO_DRIVER_DIRECTFB = 0,
        .SDL_VIDEO_DRIVER_DIRECTFB_DYNAMIC = 0,
        .SDL_VIDEO_DRIVER_DUMMY = 0,
        .SDL_VIDEO_DRIVER_OFFSCREEN = 0,
        .SDL_VIDEO_DRIVER_WINDOWS = 0,
        .SDL_VIDEO_DRIVER_WINRT = 0,
        .SDL_VIDEO_DRIVER_WAYLAND = 0,
        .SDL_VIDEO_DRIVER_RPI = 0,
        .SDL_VIDEO_DRIVER_VIVANTE = 0,
        .SDL_VIDEO_DRIVER_VIVANTE_VDK = 0,
        .SDL_VIDEO_DRIVER_OS2 = 0,
        .SDL_VIDEO_DRIVER_QNX = 0,
        .SDL_VIDEO_DRIVER_RISCOS = 0,
        .SDL_VIDEO_DRIVER_PSP = 0,
        .SDL_VIDEO_DRIVER_PS2 = 0,

        .SDL_VIDEO_DRIVER_KMSDRM = 0,
        .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC = 0,
        .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC_GBM = 0,

        .SDL_VIDEO_DRIVER_WAYLAND_QT_TOUCH = 0,
        .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC = 0,
        .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_EGL = 0,
        .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_CURSOR = 0,
        .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_XKBCOMMON = 0,
        .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_LIBDECOR = 0,

        .SDL_VIDEO_DRIVER_X11 = 0,
        .SDL_VIDEO_DRIVER_X11_DYNAMIC = 0,
        .SDL_VIDEO_DRIVER_X11_DYNAMIC_XEXT = 0,
        .SDL_VIDEO_DRIVER_X11_DYNAMIC_XCURSOR = 0,
        .SDL_VIDEO_DRIVER_X11_DYNAMIC_XINPUT2 = 0,
        .SDL_VIDEO_DRIVER_X11_DYNAMIC_XFIXES = 0,
        .SDL_VIDEO_DRIVER_X11_DYNAMIC_XRANDR = 0,
        .SDL_VIDEO_DRIVER_X11_DYNAMIC_XSS = 0,
        .SDL_VIDEO_DRIVER_X11_XCURSOR = 0,
        .SDL_VIDEO_DRIVER_X11_XDBE = 0,
        .SDL_VIDEO_DRIVER_X11_XINPUT2 = 0,
        .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_MULTITOUCH = 0,
        .SDL_VIDEO_DRIVER_X11_XFIXES = 0,
        .SDL_VIDEO_DRIVER_X11_XRANDR = 0,
        .SDL_VIDEO_DRIVER_X11_XSCRNSAVER = 0,
        .SDL_VIDEO_DRIVER_X11_XSHAPE = 0,
        .SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS = 0,
        .SDL_VIDEO_DRIVER_X11_HAS_XKBKEYCODETOKEYSYM = 0,
        .SDL_VIDEO_DRIVER_VITA = 0,
        .SDL_VIDEO_DRIVER_N3DS = 0,

        .SDL_VIDEO_RENDER_D3D = 0,
        .SDL_VIDEO_RENDER_D3D11 = 0,
        .SDL_VIDEO_RENDER_D3D12 = 0,
        .SDL_VIDEO_RENDER_OGL = 0,
        .SDL_VIDEO_RENDER_OGL_ES = 0,
        .SDL_VIDEO_RENDER_OGL_ES2 = 0,
        .SDL_VIDEO_RENDER_DIRECTFB = 0,
        .SDL_VIDEO_RENDER_METAL = 0,
        .SDL_VIDEO_RENDER_VITA_GXM = 0,
        .SDL_VIDEO_RENDER_PS2 = 0,
        .SDL_VIDEO_RENDER_PSP = 0,

        // Enable OpenGL support
        .SDL_VIDEO_OPENGL = 0,
        .SDL_VIDEO_OPENGL_ES = 0,
        .SDL_VIDEO_OPENGL_ES2 = 0,
        .SDL_VIDEO_OPENGL_BGL = 0,
        .SDL_VIDEO_OPENGL_CGL = 0,
        .SDL_VIDEO_OPENGL_GLX = 0,
        .SDL_VIDEO_OPENGL_WGL = 0,
        .SDL_VIDEO_OPENGL_EGL = 0,
        .SDL_VIDEO_OPENGL_OSMESA = 0,
        .SDL_VIDEO_OPENGL_OSMESA_DYNAMIC = 0,

        // Enable Vulkan support
        .SDL_VIDEO_VULKAN = 0,

        // Enable Metal support
        .SDL_VIDEO_METAL = 0,

        // Enable system power support
        .SDL_POWER_ANDROID = 0,
        .SDL_POWER_LINUX = is_linux,
        .SDL_POWER_WINDOWS = 0,
        .SDL_POWER_WINRT = 0,
        .SDL_POWER_MACOSX = 0,
        .SDL_POWER_UIKIT = 0,
        .SDL_POWER_HAIKU = 0,
        .SDL_POWER_EMSCRIPTEN = 0,
        .SDL_POWER_HARDWIRED = 0,
        .SDL_POWER_VITA = 0,
        .SDL_POWER_PSP = 0,
        .SDL_POWER_N3DS = 0,

        // Enable system filesystem support
        .SDL_FILESYSTEM_ANDROID = 0,
        .SDL_FILESYSTEM_HAIKU = 0,
        .SDL_FILESYSTEM_COCOA = 0,
        .SDL_FILESYSTEM_DUMMY = 0,
        .SDL_FILESYSTEM_RISCOS = 0,
        .SDL_FILESYSTEM_UNIX = is_unix,
        .SDL_FILESYSTEM_WINDOWS = 0,
        .SDL_FILESYSTEM_EMSCRIPTEN = 0,
        .SDL_FILESYSTEM_OS2 = 0,
        .SDL_FILESYSTEM_VITA = 0,
        .SDL_FILESYSTEM_PSP = 0,
        .SDL_FILESYSTEM_PS2 = 0,
        .SDL_FILESYSTEM_N3DS = 0,

        // Enable misc subsystem
        .SDL_MISC_DUMMY = 0,

        // Enable locale subsystem
        .SDL_LOCALE_DUMMY = 0,

        // Enable assembly routines
        .SDL_ALTIVEC_BLITTERS = 0,
        .SDL_ARM_SIMD_BLITTERS = 0,
        .SDL_ARM_NEON_BLITTERS = 0,

        // Whether SDL_DYNAMIC_API needs dlopen
        .DYNAPI_NEEDS_DLOPEN = 0,

        // Enable dynamic libsamplerate support
        .SDL_LIBSAMPLERATE_DYNAMIC = 0,

        // Enable ime support
        .SDL_USE_IME = 0,

        // Platform specific definitions
        .SDL_IPHONE_KEYBOARD = 0,
        .SDL_IPHONE_LAUNCHSCREEN = 0,

        .SDL_VIDEO_VITA_PIB = 0,
        .SDL_VIDEO_VITA_PVR = 0,
        .SDL_VIDEO_VITA_PVR_OGL = 0,

        .SDL_HAVE_LIBDECOR_GET_MIN_MAX = 0,
    });
}
