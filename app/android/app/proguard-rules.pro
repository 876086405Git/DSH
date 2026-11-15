# R8 rules for the release build (Flutter adds its own on top).

# Conscrypt's pre-Lollipop socket adapters reference platform classes that
# don't exist on minSdk 26; those paths are never reached.
-dontwarn com.android.org.conscrypt.SSLParametersImpl
-dontwarn org.apache.harmony.xnet.provider.jsse.SSLParametersImpl

# 不打扰模式: the privileged process is started by class name, outside R8's
# view (Shizuku UserService, `app_process … PrivilegedDisplayMain` over self-ADB),
# and talks to the app through a hand-written Binder and Parcel/Bundle protocol.
-keep class io.github.ccch1mneyyy.dsh_app.phone.background.** { *; }

# Independent Shizuku service and self-ADB/app_process command entry points.
-keep class io.github.ccch1mneyyy.dsh_app.phone.shell.** { *; }

# The one-attempt self-update UserService is loaded by Shizuku outside R8 references.
-keep class io.github.ccch1mneyyy.dsh_app.update.privileged.** { *; }

# ONNX JNI looks up exception/value classes and constructors by their original names.
# Without these, an inference error aborts the process instead of throwing OrtException.
-keep class ai.onnxruntime.** { *; }

# Bouncy Castle and Conscrypt look providers and algorithms up by name;
# libadb-android drives both for wireless-debugging pairing and TLS.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class org.conscrypt.** { *; }
-keep class io.github.muntashirakon.adb.** { *; }

# sherpa-onnx reads its Java config objects from native code: the JNI bridge asks
# for fields by name (GetFieldID "decodingMethod" and friends). Renaming them in
# the release build makes every model load fail with
# "Failed to get field ID for decodingMethod", so the whole binding keeps its names.
-keep class com.k2fsa.sherpa.onnx.** { *; }
