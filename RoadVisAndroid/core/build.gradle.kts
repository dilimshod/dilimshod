// RoadVis core logic (pure Kotlin/JVM, no Android APIs) — a port of the iOS RoadVisCore Swift package.
plugins {
    alias(libs.plugins.kotlin.jvm)
}
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}
dependencies {
    // org.json is part of Android; on the JVM it comes from Maven so core JSON parsing is unit-testable.
    compileOnly(libs.json)
    testImplementation(libs.json)
    testImplementation(libs.junit)
}
