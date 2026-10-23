import java.util.Properties
import java.security.KeyStore
import java.security.MessageDigest
import org.gradle.api.tasks.compile.JavaCompile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseProperties = Properties()
val releasePropertiesFile = rootProject.file("key.properties")
if (releasePropertiesFile.exists()) releasePropertiesFile.inputStream().use { releaseProperties.load(it) }
val releaseStore = releaseProperties.getProperty("storeFile")?.let { file(it) }
val releaseFingerprint = if (releaseStore != null && releaseStore.exists()) {
    val store = KeyStore.getInstance("PKCS12")
    releaseStore.inputStream().use { store.load(it, releaseProperties.getProperty("storePassword").toCharArray()) }
    MessageDigest.getInstance("SHA-256")
        .digest(store.getCertificate(releaseProperties.getProperty("keyAlias")).encoded)
        .joinToString("") { ((it.toInt() and 255) + 256).toString(16).substring(1) }
} else ""

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.documentfile:documentfile:1.0.1")
}

android {
    buildFeatures { buildConfig = true }
    namespace = "app.pageflow.reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.pageflow.reader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        // Public release label; Flutter uses semantic version 1.0.8 internally.
        versionName = "v1.08"
        buildConfigField("String", "RELEASE_CERT_SHA256", "\"$releaseFingerprint\"")
    }

    signingConfigs {
        create("protectedRelease") {
            if (releaseStore != null) {
                storeFile = releaseStore
                storeType = "PKCS12"
                storePassword = releaseProperties.getProperty("storePassword")
                keyPassword = releaseProperties.getProperty("keyPassword")
                keyAlias = releaseProperties.getProperty("keyAlias")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("protectedRelease")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

dependencies {
    implementation("org.apache.poi:poi-scratchpad:5.5.1")
    implementation("xerces:xercesImpl:2.12.2") { exclude(group = "xml-apis", module = "xml-apis") }
    implementation(files("libs/xml-dom-compat.jar"))
}

// This Flutter SDK generates a direct reference to the debug-only integration
// plugin even for release builds. Make that one optional registration reflective.
tasks.withType<JavaCompile>().configureEach {
    if (name.contains("Release")) {
        doFirst {
            val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            if (registrant.exists()) {
                val text = registrant.readText().replace(
                    "new dev.flutter.plugins.integration_test.IntegrationTestPlugin()",
                    "(io.flutter.embedding.engine.plugins.FlutterPlugin) Class.forName(\"dev.flutter.plugins.integration_test.IntegrationTestPlugin\").getDeclaredConstructor().newInstance()"
                )
                registrant.writeText(text)
            }
        }
    }
}

