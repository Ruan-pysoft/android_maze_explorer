package build

import "core:fmt"
import "core:os"
import "core:slice"

_ :: `
~/Android/build-tools/36.0.0/aapt package -f -M AndroidManifest.xml -I ~/Android/platforms/android-16/android.jar -S res -F android-test-app.apk build/
┬─[ruan@melkkos:~/Documents/programmeering/odin/android_test_app]─[pts/1]─[Wed 26-10-07 01:02:33]
╰─> 0 (git)[master] % ~/Android/build-tools/36.0.0/zipalign -f 4 android-test-app.apk aligned-android-test-app.apk
`

main :: proc() {
	os.remove_all("build/")
	os.make_directory_all("build/lib/arm64-v8a/")
	os.remove_all("out/")
	os.make_directory_all("out/")
	android_sdk_root, _ := os.lookup_env("ANDROID_SDK_ROOT", context.allocator)
	os.set_env("ODIN_ANDROID_NDK", fmt.aprintf("{}/ndk/30.0.16248370/", android_sdk_root))
	os.set_env("ODIN_ANDROID_SDK", android_sdk_root)
	home, _ := os.lookup_env("HOME", context.allocator)

	os.copy_directory_all("build/", "app/")

	ensure(run_cmd({
		"odin", "build",
		"src/",
		"-o:speed",
		"-out:build/lib/arm64-v8a/libandroid-test-app.so",
		"-build-mode:shared",
		"-target=linux_arm64",
		"-subtarget:android",
		"-minimum-os-version:30",
	}))

	ensure(run_cmd({
		"odin", "bundle", "android",
		"build",
		"-minimum-os-version:30",
		"-out:out/android-test-app.apk"
	}, enable_stdin=true))
}

run_cmd :: proc(cmd: []string, enable_stdin := false, location := #caller_location) -> (ok: bool) {
	fmt.println("Running command:", cmd)

	build_cmd := os.Process_Desc {
		command = cmd,
		stderr = os.stderr,
		stdout = os.stdout,
		stdin = enable_stdin ? os.stdin : nil,
	}
	build_proc, build_proc_err := os.process_start(build_cmd)
	if build_proc_err != nil {
		fmt.eprintfln("{}:\nError running command {}: {}", location, cmd, build_proc_err)
		return false
	}
	build_state, build_state_err := os.process_wait(build_proc)
	if build_state_err != nil {
		fmt.eprintfln("{}:\nError running command {}: {}", location, cmd, build_state_err)
		return false
	}
	ensure(build_state.exited)
	if build_state.exit_code != 0 {
		fmt.eprintfln("{}:\nCommand exited with nonzero exit code {}: {}", location, cmd, build_state.exit_code)
		return false
	}

	return true
}
