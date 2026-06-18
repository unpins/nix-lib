//===-- cxx_sources.inc - libc++ / libc++abi / libunwind file lists -------===//
//
// M4: the C++ runtime source lists, transcribed from zig 0.16's
// src/libs/libcxx.zig + libunwind.zig. Paths are relative to the embedded tree
// roots VROOT/cxx/{libcxx,libcxxabi,libunwind}. The sources themselves come
// from OUR llvm-project monorepo (version-matched to the compiler, LLVM 21.1.x),
// not from zig — zig is the recipe (which files, which flags) only.
//
//===----------------------------------------------------------------------===//

// libc++abi (relative to cxx/libcxxabi/). cxa_noexception.cpp is wasi-only and
// omitted; cxa_thread_atexit.cpp is threaded-only (we are threaded, so kept).
static const char *const kLibcxxabiFiles[] = {
    "src/cxa_aux_runtime.cpp",
    "src/cxa_default_handlers.cpp",
    "src/cxa_demangle.cpp",
    "src/cxa_exception_storage.cpp",
    "src/cxa_guard.cpp",
    "src/cxa_handlers.cpp",
    "src/cxa_vector.cpp",
    "src/cxa_virtual.cpp",
    "src/stdlib_exception.cpp",
    "src/stdlib_stdexcept.cpp",
    "src/stdlib_typeinfo.cpp",
    "src/stdlib_new_delete.cpp",
    "src/abort_message.cpp",
    "src/fallback_malloc.cpp",
    "src/private_typeinfo.cpp",
    "src/cxa_exception.cpp",
    "src/cxa_personality.cpp",
    "src/cxa_thread_atexit.cpp",
};

// libc++ base (relative to cxx/libcxx/). win32 support files are skipped at
// build time (non-windows). int128_builtins.cpp omitted (provided by builtins).
static const char *const kLibcxxBaseFiles[] = {
    "src/algorithm.cpp",
    "src/any.cpp",
    "src/bind.cpp",
    "src/call_once.cpp",
    "src/charconv.cpp",
    "src/chrono.cpp",
    "src/error_category.cpp",
    "src/exception.cpp",
    "src/expected.cpp",
    "src/filesystem/directory_entry.cpp",
    "src/filesystem/directory_iterator.cpp",
    "src/filesystem/filesystem_clock.cpp",
    "src/filesystem/filesystem_error.cpp",
    "src/filesystem/operations.cpp",
    "src/filesystem/path.cpp",
    "src/fstream.cpp",
    "src/functional.cpp",
    "src/hash.cpp",
    "src/ios.cpp",
    "src/ios.instantiations.cpp",
    "src/iostream.cpp",
    "src/locale.cpp",
    "src/memory.cpp",
    "src/memory_resource.cpp",
    "src/new.cpp",
    "src/new_handler.cpp",
    "src/new_helpers.cpp",
    "src/optional.cpp",
    "src/ostream.cpp",
    "src/print.cpp",
    "src/random.cpp",
    "src/random_shuffle.cpp",
    "src/regex.cpp",
    "src/ryu/d2fixed.cpp",
    "src/ryu/d2s.cpp",
    "src/ryu/f2s.cpp",
    "src/stdexcept.cpp",
    "src/string.cpp",
    "src/strstream.cpp",
    "src/system_error.cpp",
    "src/typeinfo.cpp",
    "src/valarray.cpp",
    "src/variant.cpp",
    "src/vector.cpp",
    "src/verbose_abort.cpp",
};

// libc++ thread-only (kept: we build threaded). win32 thread file skipped.
static const char *const kLibcxxThreadFiles[] = {
    "src/atomic.cpp",
    "src/barrier.cpp",
    "src/condition_variable.cpp",
    "src/condition_variable_destructor.cpp",
    "src/future.cpp",
    "src/mutex.cpp",
    "src/mutex_destructor.cpp",
    "src/shared_mutex.cpp",
    "src/thread.cpp",
};

// Windows (mingw) libc++ support sources, appended only for *-windows-gnu. zig
// lists locale_win32.cpp/support.cpp in the base set and thread_win32.cpp in the
// thread set, each skipped off-Windows. locale_win32/support provide the Win32
// locale + asprintf shims libc++ needs where musl's xlocale/POSIX don't exist;
// thread_win32 implements the __libcpp thread API on the Win32 API (zig builds
// libc++ with the win32 thread API on Windows — see cxx_config_site_win.h).
static const char *const kLibcxxWin32Files[] = {
    "src/support/win32/locale_win32.cpp",
    "src/support/win32/support.cpp",
};
static const char *const kLibcxxWin32ThreadFiles[] = {
    "src/support/win32/thread_win32.cpp",
};

// libunwind (relative to cxx/libunwind/). Unwind-wasm.c is wasi-only; the build
// skips any source not present in the VFS (gcc_personality_v0.c was removed
// upstream after the zig pin, so it is simply absent and skipped).
static const char *const kLibunwindFiles[] = {
    "src/libunwind.cpp",
    "src/Unwind-EHABI.cpp",
    "src/Unwind-seh.cpp",
    "src/UnwindLevel1.c",
    "src/UnwindLevel1-gcc-ext.c",
    "src/Unwind-sjlj.c",
    "src/Unwind-wasm.c",
    "src/UnwindRegistersRestore.S",
    "src/UnwindRegistersSave.S",
    "src/gcc_personality_v0.c",
};
