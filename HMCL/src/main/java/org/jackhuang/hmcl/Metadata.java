// SPDX-FileCopyrightText: Copyright (C) 2021 The HMCL Authors
// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-HMCL
package org.jackhuang.hmcl;

import org.jackhuang.hmcl.util.StringUtils;
import org.jackhuang.hmcl.util.io.JarUtils;
import org.jackhuang.hmcl.util.platform.Architecture;
import org.jackhuang.hmcl.util.platform.OperatingSystem;
import org.jetbrains.annotations.Nullable;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.EnumSet;

/**
 * Stores metadata about this application.
 */
public final class Metadata {
    private Metadata() {
    }

    public static final String NAME = "HMCL";
    public static final String FULL_NAME = "Hello Minecraft! Launcher";
    public static final String VERSION = System.getProperty("hmcl.version.override", JarUtils.getAttribute("hmcl.version", "@develop@"));

    /// Explicit Application User Model ID used for Windows taskbar grouping and pinning.
    public static final String WINDOWS_APP_USER_MODEL_ID = "org.jackhuang.hmcl";

    public static final String TITLE = NAME + " " + VERSION;

    /// Whether the build metadata identifies this launcher as an official build.
    public static final boolean OFFICIAL_BUILD = Boolean.parseBoolean(JarUtils.getAttribute("hmcl.official", "false"));

    public static final int MINIMUM_REQUIRED_JAVA_VERSION = 17;
    public static final int MINIMUM_SUPPORTED_JAVA_VERSION = 17;
    public static final int RECOMMENDED_JAVA_VERSION = 21;

    public static final String PUBLISH_URL = "https://hmcl.huangyuhui.net";
    public static final String REPOSITORY_URL = "https://github.com/HMCL-dev/HMCL";

    /// The source repository of this fork.
    public static final String FORK_REPOSITORY_URL = "https://github.com/Max-RM/HMCL_offline";

    public static final String HMCL_UPDATE_URL = System.getProperty("hmcl.update_source.override", PUBLISH_URL + "/api/update_link");
    public static final String MANUAL_UPDATE_URL = "https://github.com/HMCL-dev/HMCL/releases";

    public static final String DOCS_URL = "https://docs.hmcl.net";
    public static final String CONTACT_URL = DOCS_URL + "/help.html";
    public static final String CHANGELOG_URL = DOCS_URL + "/changelog/";
    public static final String GROUPS_URL = "https://www.bilibili.com/opus/905435541874409529";

    public static final String BUILD_CHANNEL = JarUtils.getAttribute("hmcl.version.type", "nightly");
    public static final String GITHUB_SHA = JarUtils.getAttribute("hmcl.version.hash", null);

    /// The absolute working directory of the launcher process, normally the directory containing the launcher jar or executable.
    public static final Path CURRENT_DIRECTORY = Path.of(System.getProperty("user.dir")).toAbsolutePath().normalize();

    /// The name of the marker file that enables [#FORCE_LOCAL_ROOT].
    public static final String FORCE_LOCAL_ROOT_MARKER_NAME = "force-local-root";

    /// The marker file whose presence forces all launcher data into the launcher's own directory.
    ///
    /// The marker is read once during class initialization; changing it requires a launcher restart.
    public static final Path FORCE_LOCAL_ROOT_MARKER;

    /// Whether all launcher data is forced into [CURRENT_DIRECTORY] and [HMCL_LOCAL_HOME].
    ///
    /// When enabled, the shared user data directory and the default Minecraft directory are redirected
    /// away from the user profile so that the launcher does not write to `%APPDATA%` or its Unix equivalents.
    public static final boolean FORCE_LOCAL_ROOT;

    /// The default Minecraft directory used by the launcher.
    ///
    /// This is the user-profile `.minecraft` directory unless [#FORCE_LOCAL_ROOT] is enabled, in which
    /// case it is `[CURRENT_DIRECTORY]/.minecraft`.
    public static final Path MINECRAFT_DIRECTORY;

    /// The shared user data directory that stores accounts, user settings and user state.
    ///
    /// This is the user-profile HMCL directory unless [#FORCE_LOCAL_ROOT] is enabled, in which case it
    /// is the same as [HMCL_LOCAL_HOME].
    public static final Path HMCL_USER_HOME;

    /// The per-instance launcher data directory, normally `[CURRENT_DIRECTORY]/.hmcl`.
    public static final Path HMCL_LOCAL_HOME;

    /// The directory that stores launcher dependencies and native libraries.
    public static final Path DEPENDENCIES_DIRECTORY;

    static {
        String hmclCurrentDir = System.getProperty("hmcl.dir", System.getenv("HMCL_LOCAL_HOME"));
        HMCL_LOCAL_HOME = StringUtils.isNotBlank(hmclCurrentDir)
                ? Path.of(hmclCurrentDir).toAbsolutePath().normalize()
                : CURRENT_DIRECTORY.resolve(".hmcl");

        // The marker has to be resolved before the user home and Minecraft directory are computed,
        // because both must be redirected while those constants are initialized.
        FORCE_LOCAL_ROOT_MARKER = HMCL_LOCAL_HOME.resolve(FORCE_LOCAL_ROOT_MARKER_NAME);
        FORCE_LOCAL_ROOT = Files.isRegularFile(FORCE_LOCAL_ROOT_MARKER);

        String hmclHome = System.getProperty("hmcl.home", System.getenv("HMCL_USER_HOME"));
        if (FORCE_LOCAL_ROOT) {
            HMCL_USER_HOME = HMCL_LOCAL_HOME;
        } else if (StringUtils.isBlank(hmclHome)) {
            if (OperatingSystem.CURRENT_OS.isLinuxOrBSD()) {
                String xdgData = System.getenv("XDG_DATA_HOME");
                if (StringUtils.isNotBlank(xdgData)) {
                    HMCL_USER_HOME = Path.of(xdgData, "hmcl").toAbsolutePath().normalize();
                } else {
                    HMCL_USER_HOME = Path.of(System.getProperty("user.home"), ".local", "share", "hmcl").toAbsolutePath().normalize();
                }
            } else {
                HMCL_USER_HOME = OperatingSystem.getWorkingDirectory("hmcl");
            }
        } else {
            HMCL_USER_HOME = Path.of(hmclHome).toAbsolutePath().normalize();
        }

        MINECRAFT_DIRECTORY = FORCE_LOCAL_ROOT
                ? CURRENT_DIRECTORY.resolve(".minecraft").toAbsolutePath().normalize()
                : OperatingSystem.getWorkingDirectory("minecraft");

        String hmclDependencies = System.getProperty("hmcl.dependencies.dir", System.getenv("HMCL_DEPENDENCIES_DIR"));
        DEPENDENCIES_DIRECTORY = StringUtils.isNotBlank(hmclDependencies)
                ? Path.of(hmclDependencies).toAbsolutePath().normalize()
                : HMCL_LOCAL_HOME.resolve("dependencies");
    }

    public static boolean isStable() {
        return "stable".equals(BUILD_CHANNEL);
    }

    public static boolean isDev() {
        return "dev".equals(BUILD_CHANNEL);
    }

    public static boolean isNightly() {
        return !isStable() && !isDev();
    }

    public static @Nullable String getSuggestedJavaDownloadLink() {
        if (OperatingSystem.CURRENT_OS == OperatingSystem.LINUX && Architecture.SYSTEM_ARCH == Architecture.LOONGARCH64_OW)
            return "https://www.loongnix.cn/zh/api/java/downloads-jdk21/index.html";
        else {
            EnumSet<Architecture> supportedArchitectures;
            if (OperatingSystem.CURRENT_OS == OperatingSystem.WINDOWS)
                supportedArchitectures = EnumSet.of(Architecture.X86_64, Architecture.X86, Architecture.ARM64);
            else if (OperatingSystem.CURRENT_OS == OperatingSystem.LINUX)
                supportedArchitectures = EnumSet.of(
                        Architecture.X86_64, Architecture.X86,
                        Architecture.ARM64, Architecture.ARM32,
                        Architecture.RISCV64, Architecture.LOONGARCH64
                );
            else if (OperatingSystem.CURRENT_OS == OperatingSystem.MACOS)
                supportedArchitectures = EnumSet.of(Architecture.X86_64, Architecture.ARM64);
            else
                supportedArchitectures = EnumSet.noneOf(Architecture.class);
            if (supportedArchitectures.contains(Architecture.SYSTEM_ARCH))
                return String.format("https://docs.hmcl.net/downloads/%s/%s.html",
                        OperatingSystem.CURRENT_OS.getCheckedName(),
                        Architecture.SYSTEM_ARCH.getCheckedName()
                );
            else
                return null;
        }
    }

    /// Directory under [HMCL_LOCAL_HOME] that holds a launcher-bundled modpack for automatic install.
    public static final String BUNDLED_MODPACK_DIRECTORY_NAME = "modpack";

    /// Returns the directory for a launcher-bundled modpack (`[HMCL_LOCAL_HOME]/modpack`).
    public static Path getBundledModpackDirectory() {
        return HMCL_LOCAL_HOME.resolve(BUNDLED_MODPACK_DIRECTORY_NAME);
    }

    /// Returns the bundled modpack package under [getBundledModpackDirectory], if present.
    ///
    /// Prefers `modpack.zip` over `modpack.mrpack` when both exist. Presence of the package is the
    /// signal to offer automatic install; the file is removed after a successful install.
    ///
    /// @return the modpack path, or `null` when no package is present
    public static @Nullable Path findBundledModpackFile() {
        Path directory = getBundledModpackDirectory();
        Path zipModpack = directory.resolve("modpack.zip");
        if (Files.isRegularFile(zipModpack)) {
            return zipModpack;
        }
        Path mrpackModpack = directory.resolve("modpack.mrpack");
        if (Files.isRegularFile(mrpackModpack)) {
            return mrpackModpack;
        }
        return null;
    }

}
