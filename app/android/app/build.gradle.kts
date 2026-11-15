import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keyProps = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

// Debug builds use the release key only when it is all there; they are never the build
// that should stop over a half-filled key.properties.
// A password may be nothing but spaces; a path or an alias may not.
val hasWholeReleaseKey = listOf("storeFile", "keyAlias").all { !keyProps.getProperty(it).isNullOrBlank() } &&
    listOf("storePassword", "keyPassword").all { !keyProps.getProperty(it).isNullOrEmpty() } &&
    file(keyProps.getProperty("storeFile")).exists()

// Per-ABI runtime bundles produced by runtime/build-runtime.sh.
val runtimeOut = rootProject.file("../../runtime/out")
// libtawcroot.so for the opt-in tawcroot launch method (runtime/tawcroot/build.py; missing = unavailable).
val tawcrootOut = rootProject.file("../../runtime/out-tawcroot")

// versionCode is the build minute, same encoding as tooling/build_number.py:
// (year - 2026) * 10^8 + MMDDhhmm at UTC+8. tooling/build-apk.sh passes it as
// --build-number; this covers builds that skip the script (flutter run, the
// IDE), where pubspec's `+1` placeholder would be a downgrade and make
// `flutter run` uninstall the installed app, data included.
fun buildMinuteVersionCode(): Int {
    val t = OffsetDateTime.now(ZoneOffset.ofHours(8))
    return (t.year - 2026) * 100_000_000 + t.monthValue * 1_000_000 + t.dayOfMonth * 10_000 + t.hour * 100 + t.minute
}

android {
    namespace = "io.github.ccch1mneyyy.dsh_app"
    compileSdk = flutter.compileSdkVersion
    // The device tests under src/androidTest are AndroidTestCase tests; these platform libraries
    // carry that API (no longer in android.jar). Device-test classpath only.
    useLibrary("android.test.base")
    useLibrary("android.test.runner")
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 共存版：与官方版（io.github.ccch1mneyyy.dsh_app）包名不同，因此可以同时
        // 安装、各自保留数据，也不需要同一把签名钥匙。namespace 仍是原包名：
        // 它只决定 R 类与 BuildConfig 的生成位置，与安装身份无关。
        applicationId = "io.github.ccch1mneyyy.dsh_app.coexist"
        // java.nio.file (symlinks while unpacking the rootfs) needs API 26.
        minSdk = 26
        // Target 28 like Termux, so the API 29+ exec restriction on app-private
        // files does not apply to binaries inside the rootfs.
        targetSdk = 28
        versionCode = flutter.versionCode.takeIf { it > 1 } ?: buildMinuteVersionCode()
        versionName = flutter.versionName
    }

    // Kotlin code reads its own package from BuildConfig instead of hard-coding it:
    // the coexist build ships a different applicationId, and every runtime check
    // (own-app guards, launcher aliases, privileged grants) has to follow it.
    buildFeatures {
        buildConfig = true
    }

    flavorDimensions += "abi"
    productFlavors {
        create("arm64") {
            dimension = "abi"
            ndk { abiFilters += "arm64-v8a" }
        }
        create("x64") {
            dimension = "abi"
            ndk { abiFilters += "x86_64" }
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir(File(tawcrootOut, "jniLibs"))
        }
        getByName("arm64") {
            assets.srcDir(File(runtimeOut, "arm64-v8a/assets"))
            jniLibs.srcDir(File(runtimeOut, "arm64-v8a/jniLibs"))
            // 内置模型 (sherpa-onnx) and the model itself ship inside the APK.
            assets.srcDir("src/main/assets/voice")
        }
        getByName("x64") {
            assets.srcDir(File(runtimeOut, "x86_64/assets"))
            jniLibs.srcDir(File(runtimeOut, "x86_64/jniLibs"))
            assets.srcDir("src/main/assets/voice")
        }
    }

    packaging {
        // proot and friends ship as lib*.so; they must be extracted to
        // nativeLibraryDir so they can be executed.
        jniLibs {
            useLegacyPackaging = true
            // sherpa_onnx_android_* 1.13.4 and ORT Android 1.27.0 each ship an ORT 1.27.0
            // (sherpa's own build): either serves both, with the same exports.
            pickFirsts += "**/libonnxruntime.so"
            // 本地 AAR（JitPack 元数据坏了才用文件）和 sherpa_onnx_android_* 都带这几个
            // 同名 .so；内容相同，任取一份即可。
            pickFirsts += listOf("**/libsherpa-onnx-c-api.so", "**/libsherpa-onnx-cxx-api.so", "**/libsherpa-onnx-jni.so")
            // Keep the Termux binaries byte-identical to runtime/out (their hashes are in the manifest).
            keepDebugSymbols += listOf("**/libproot.so", "**/libproot-loader.so", "**/libtalloc.so", "**/libandroid-shmem.so", "**/libtawcroot.so")
        }
    }

    lint {
        // targetSdk 28 is deliberate (see docs/architecture.md); not a Play build.
        disable += "ExpiredTargetSdkVersion"
    }

    androidResources {
        // 内置模型的 onnx 必须不压缩：① `AssetManager.openFd` 对压缩资源会抛
        // FileNotFoundException；② 首次落盘要读 228 MB，压缩后还要边解压边写，慢一倍。
        // 代价是 APK 大一点（不压缩约 228 MB，压缩后 152 MB），换来的是可 mmap 的资源。
        noCompress += listOf("gz", "xz", "zst", "tar", "onnx")
    }

    signingConfigs {
        if (!keyProps.isEmpty) {
            create("release") {
                storeFile = keyProps.getProperty("storeFile")?.let { file(it) }
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
                // All three schemes: AGP drops v1 for minSdk 24+, but some installers and
                // security scanners on Chinese ROMs still read the JAR signature.
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        debug {
            // tooling/dev-run.sh installs debug over the release build on a phone, data
            // kept: Android only allows that with the same key.
            if (hasWholeReleaseKey) signingConfig = signingConfigs.getByName("release")
        }
        release {
            // Use the release key when configured; local builds without key.properties fall back to debug.
            signingConfig = signingConfigs.getByName(if (keyProps.isEmpty) "debug" else "release")
            // Ours on top of Flutter's: phone control's privileged process and
            // its TLS libraries are reached by class name (see the file).
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Local JVM tests need the desktop JNI library, not Android's classes.jar.
configurations.matching { it.name.endsWith("UnitTestRuntimeClasspath") }.configureEach {
    exclude(group = "com.microsoft.onnxruntime", module = "onnxruntime-android")
}

dependencies {
    // MIT. 1.27.0 exactly: sherpa-onnx 1.13.4 (pubspec.yaml) links ORT 1.27.0's symbols.
    // 1.23.2 crashed on Snapdragon 8 Elite with Android 16 (SME, onnxruntime#27884).
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.27.0")
    testImplementation("com.microsoft.onnxruntime:onnxruntime:1.27.0")
    // Bundled Chinese OCR. SDK statistics disclosed separately; initialization is opt-in per use.
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")

    // sherpa's Java binding is Kotlin; the app is Java/Kotlin mixed but does not otherwise
    // depend on the Kotlin runtime.
    // 内置模型：sherpa-onnx 的 Kotlin 绑定 + jni 库。
    // 用本地 AAR 而不是 JitPack 坐标：JitPack 给 v2.0.1 生成的元数据 group 与坐标不一致
    // （"bad group: expected='com.github.k2-fsa/sherpa-onnx'"），依赖解析阶段就失败。
    // 这个文件就是 JitPack 上的同一个 v2.0.1 构建（47 MB，含四个 ABI）。
    implementation(files("libs/sherpa-onnx-v2.0.1.aar"))
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.0.21")
    testImplementation("junit:junit:4.13.2")
    // Android stubs do not implement JSONObject in local JVM upgrade tests.
    testImplementation("org.json:json:20240303")

    // .tar.xz support for the rootfs bundle.
    implementation("org.tukaani:xz:1.10")

    // 不打扰模式 (phone/background): a shell-uid privileged display via Shizuku or self-ADB.
    implementation("dev.rikka.shizuku:api:13.1.5")       // MIT
    implementation("dev.rikka.shizuku:provider:13.1.5")  // MIT
    implementation("com.github.MuntashirAkon:libadb-android:3.1.1") // used under its Apache-2.0 option; pulls in spake2-android (LGPL-3.0)
    implementation("org.conscrypt:conscrypt-android:2.8.0")         // Apache-2.0: libadb TLS/pairing
    // MIT: self-signed adb client cert. The same jdk15to18 family libadb-android
    // pulls in (bcprov-jdk15to18:1.81); adding jdk18on next to it duplicates every class.
    implementation("org.bouncycastle:bcpkix-jdk15to18:1.81")
    implementation("androidx.webkit:webkit:1.15.0") // Apache-2.0: web islands' force dark (webview_flutter's own version)
}
