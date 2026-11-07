plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.langhua98.xiaoju.remote"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.langhua98.xiaoju.remote"
        // 最低 Android 4.2（API 17）
        minSdk = 17
        targetSdk = 35
        versionCode = 9
        versionName = "0.9"
        multiDexEnabled = true
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
        }
        getByName("release") {
            isMinifyEnabled = false
            // 用 debug 签名，出来的 release APK 也能直接装
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }
    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}

dependencies {
    // 4.2 自带的 TLS 太旧：用 Conscrypt 提供 TLS 1.2/1.3。2.5.2 是最后一个支持 API 9+ 的版本
    implementation("org.conscrypt:conscrypt-android:2.5.2")
    // API 21 以下方法数超 64K 时要用
    implementation("androidx.multidex:multidex:2.0.1")
    // 直播用的 WebSocket：OkHttp 3.12 是官方留给老安卓的分支（支持 Android 2.3+）
    implementation("com.squareup.okhttp3:okhttp:3.12.13")

    testImplementation("junit:junit:4.13.2")
    // 安卓自带的 org.json 在电脑上跑测试时是空壳，测试用真的
    testImplementation("org.json:json:20231013")
}
