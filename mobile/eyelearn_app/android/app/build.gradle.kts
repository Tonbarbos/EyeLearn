plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "br.edu.ucl.eyelearn"
    compileSdk = 35

    defaultConfig {
        applicationId = "br.edu.ucl.eyelearn"
        // O MediaPipe Tasks Vision exige 24; a câmera frontal com CameraX
        // também se comporta melhor a partir daí.
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    // O arquivo .task é um modelo já comprimido; comprimi-lo de novo no APK
    // impede o MediaPipe de mapeá-lo em memória.
    androidResources {
        noCompress += "task"
    }
}

dependencies {
    implementation("com.google.mediapipe:tasks-vision:0.10.14")

    val cameraX = "1.3.4"
    implementation("androidx.camera:camera-core:$cameraX")
    implementation("androidx.camera:camera-camera2:$cameraX")
    implementation("androidx.camera:camera-lifecycle:$cameraX")
}

flutter {
    source = "../.."
}
