allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
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

    // 统一所有插件子项目的 Java/Kotlin 编译目标为 17，匹配 Kotlin 2.2 默认 JVM target。
    // 解决部分插件（如 flutter_avif_android 声明 Java 11、audio_session 声明 Kotlin 11）导致的
    // "Inconsistent JVM Target Compatibility" 构建失败。
    // 必须在 evaluationDependsOn 之前注册 afterEvaluate，否则项目已评估完无法再 hook。
    afterEvaluate {
        // 1. 通过反射修改 android extension 的 compileOptions，避免 AGP import 依赖
        extensions.findByName("android")?.let { androidExt ->
            try {
                val compileOptions = androidExt.javaClass
                    .getMethod("getCompileOptions")
                    .invoke(androidExt)
                compileOptions.javaClass
                    .getMethod("setSourceCompatibility", Any::class.java)
                    .invoke(compileOptions, JavaVersion.VERSION_17)
                compileOptions.javaClass
                    .getMethod("setTargetCompatibility", Any::class.java)
                    .invoke(compileOptions, JavaVersion.VERSION_17)
            } catch (_: Exception) {
                // 非 Android 子项目，跳过
            }
        }
        // 2. 兜底：直接覆盖 JavaCompile task 的 target
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
        // 3. 兜底：覆盖 Kotlin compile task 的 jvmTarget（task 名形如 compileReleaseKotlin）
        //    用名字匹配 + 反射，避免 import KGP
        tasks.matching {
            it.name.startsWith("compile") && it.name.endsWith("Kotlin")
        }.configureEach {
            val task = this
            try {
                val kotlinOptions = task.javaClass
                    .getMethod("getKotlinOptions")
                    .invoke(task)
                kotlinOptions.javaClass
                    .getMethod("setJvmTarget", String::class.java)
                    .invoke(kotlinOptions, "17")
            } catch (_: Exception) {
                // 不是 Kotlin compile task 或 API 不可用，跳过
            }
        }

        // 4. flutter_avif_android 3.1.0 同时包含同名 Java/Kotlin 实现。
        //    仅在本项目的 source set 中排除 Java 版，禁止改写全局 pub-cache。
        if (project.name == "flutter_avif_android") {
            val androidExt = extensions.getByName("android")
            val sourceSets = androidExt.javaClass.getMethod("getSourceSets")
                .invoke(androidExt) as NamedDomainObjectContainer<*>
            val mainSourceSet = sourceSets.getByName("main")!!
            val javaSources = mainSourceSet.javaClass.getMethod("getJava").invoke(mainSourceSet)
            // Kotlin 编译器也会扫描 Java 根目录，仅 exclude 不足以消除重复声明。
            // 该插件的 java 目录仅有这一份重复实现，保留 Kotlin 版本。
            javaSources.javaClass.getMethod("setSrcDirs", Iterable::class.java).invoke(
                javaSources,
                emptyList<String>(),
            )
        }

        // 5. quickjs_engine 0.1.1 的 CMake 漏链 NDK liblog,bridge 源码却用
        //    __android_log_print → arm64 release 链接 undefined symbol。
        //    经 gradle 给 CMake 注入链接参数补 -llog,不改 pub 缓存内容。
        if (project.name == "quickjs_engine") {
            extensions.findByName("android")?.let { androidExt ->
                try {
                    val defaultConfig = androidExt.javaClass
                        .getMethod("getDefaultConfig")
                        .invoke(androidExt)
                    val externalNativeBuild = defaultConfig.javaClass
                        .getMethod("getExternalNativeBuild")
                        .invoke(defaultConfig)
                    val cmake = externalNativeBuild.javaClass
                        .getMethod("getCmake")
                        .invoke(externalNativeBuild)
                    @Suppress("UNCHECKED_CAST")
                    val arguments = cmake.javaClass
                        .getMethod("getArguments")
                        .invoke(cmake) as MutableList<String>
                    arguments.add("-DCMAKE_SHARED_LINKER_FLAGS=-llog")
                    logger.lifecycle("Patched quickjs_engine: link NDK liblog")
                } catch (e: Exception) {
                    logger.warn("quickjs_engine liblog patch failed: $e")
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
