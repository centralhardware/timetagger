plugins {
    kotlin("jvm") version "2.3.21"
    kotlin("plugin.serialization") version "2.3.21"
    application
}

group = "timetagger"
version = "27.0.0"

repositories { mavenCentral() }

val ktorVersion = "3.5.1"

dependencies {
    implementation("io.ktor:ktor-server-core:$ktorVersion")
    implementation("io.ktor:ktor-server-cio:$ktorVersion")
    implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    implementation("io.ktor:ktor-serialization-kotlinx-json:$ktorVersion")
    implementation("io.ktor:ktor-server-auth:$ktorVersion")
    implementation("io.ktor:ktor-server-status-pages:$ktorVersion")
    implementation("org.postgresql:postgresql:42.7.8")
    implementation("com.zaxxer:HikariCP:7.0.2")
    implementation("com.auth0:java-jwt:4.5.0")
    implementation("at.favre.lib:bcrypt:0.10.2")
    implementation("ch.qos.logback:logback-classic:1.5.20")

    testImplementation(kotlin("test"))
    testImplementation("io.ktor:ktor-server-test-host:$ktorVersion")
    testImplementation("io.zonky.test:embedded-postgres:2.1.1")
}

java { targetCompatibility = JavaVersion.VERSION_25; sourceCompatibility = JavaVersion.VERSION_25 }

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_25) } }

application { mainClass.set("timetagger.MainKt") }

tasks.processResources {
    filesMatching("version.txt") { expand("version" to project.version) }
}

tasks.test {
    useJUnitPlatform()
}

tasks.register<Jar>("fatJar") {
    archiveFileName.set("timetagger.jar")
    manifest { attributes["Main-Class"] = "timetagger.MainKt" }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(sourceSets.main.get().output)
    dependsOn(configurations.runtimeClasspath)
    from({ configurations.runtimeClasspath.get().filter { it.name.endsWith("jar") }.map { zipTree(it) } }) {
        exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA")
    }
}
