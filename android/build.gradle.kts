allprojects {
    repositories {
        providers.environmentVariable("FQAPP_FLUTTER_MAVEN").orNull?.let { localMaven ->
            maven {
                url = uri(localMaven)
                content { includeGroup("io.flutter") }
            }
        }
        val useMirrors = providers.environmentVariable("FQAPP_USE_MAVEN_MIRRORS")
            .orNull?.equals("false", ignoreCase = true) != true
        if (useMirrors) {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/central") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
        }
        google()
        mavenCentral()
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

// Flutter's integration_test requests dynamic test versions, which query
// every repository even when its artifacts are cached. Keep device validation
// reproducible with stable AndroidX libraries (only the test plugin uses them).
subprojects {
    if (name == "integration_test") {
        configurations.configureEach {
            resolutionStrategy.eachDependency {
                val pinned = when ("${requested.group}:${requested.name}") {
                    "androidx.test:runner" -> "1.6.2"
                    "androidx.test:rules" -> "1.6.1"
                    "androidx.test.espresso:espresso-core" -> "3.6.1"
                    else -> null
                }
                if (pinned != null) {
                    useVersion(pinned)
                    because("Use fixed stable test libraries for device acceptance")
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
