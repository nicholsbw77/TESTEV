allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jcenter.bintray.com") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Fix legacy plugins (e.g. flutter_bluetooth_serial 0.4.0):
//   1. Inject namespace from AndroidManifest.xml when missing (AGP 8+ requirement)
//   2. Bump compileSdk to 34 when set below 31 (android:attr/lStar needs API 31+)
subprojects {
    val fixLegacy: Project.() -> Unit = {
        val androidExtension =
            extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        if (androidExtension != null) {
            if (androidExtension.namespace == null) {
                val manifestFile = file("src/main/AndroidManifest.xml")
                if (manifestFile.exists()) {
                    val packageName =
                        Regex("package=\"([^\"]+)\"").find(manifestFile.readText())
                            ?.groupValues?.get(1)
                    if (packageName != null) {
                        androidExtension.namespace = packageName
                    }
                }
            }
            val sdk = androidExtension.compileSdkVersion?.removePrefix("android-")?.toIntOrNull()
            if (sdk != null && sdk < 31) {
                androidExtension.compileSdkVersion(34)
            }
        }
    }
    if (state.executed) {
        fixLegacy()
    } else {
        afterEvaluate { fixLegacy() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
