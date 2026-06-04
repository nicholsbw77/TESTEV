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

// Inject a namespace for legacy plugins (e.g. flutter_bluetooth_serial 0.4.0)
// that declare `package` in their AndroidManifest.xml but no `namespace` in
// build.gradle. AGP 8+ requires an explicit namespace and fails the build
// otherwise.
//
// The earlier evaluationDependsOn(":app") block force-evaluates some projects
// before this runs, so afterEvaluate can't be registered on them. Apply the fix
// immediately for already-evaluated projects, otherwise register it to run
// during evaluation (before AGP's own afterEvaluate creates the variants).
subprojects {
    val fixNamespace: Project.() -> Unit = {
        val androidExtension =
            extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        if (androidExtension != null && androidExtension.namespace == null) {
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
    }
    if (state.executed) {
        fixNamespace()
    } else {
        afterEvaluate { fixNamespace() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
