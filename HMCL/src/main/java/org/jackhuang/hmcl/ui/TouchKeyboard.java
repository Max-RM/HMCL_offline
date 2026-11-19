// SPDX-FileCopyrightText: Copyright (C) 2026 The HMCL Authors
// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-HMCL
package org.jackhuang.hmcl.ui;

import com.sun.jna.Function;
import com.sun.jna.Memory;
import com.sun.jna.Native;
import com.sun.jna.Pointer;
import com.sun.jna.ptr.PointerByReference;
import javafx.scene.Node;
import javafx.scene.Scene;
import javafx.scene.control.TextInputControl;
import javafx.scene.input.MouseEvent;
import org.jackhuang.hmcl.util.Lang;
import org.jackhuang.hmcl.util.platform.OperatingSystem;
import org.jackhuang.hmcl.util.platform.windows.Ole32;
import org.jackhuang.hmcl.util.platform.windows.User32;
import org.jetbrains.annotations.NotNullByDefault;
import org.jetbrains.annotations.Nullable;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;

import static org.jackhuang.hmcl.util.logging.Logger.LOG;

/// Shows the Windows touch keyboard when the user taps an editable text field.
///
/// The integration is enabled only on Windows devices that report touch input, so desktop users
/// without a touchscreen are not affected. On those devices, tapping any [TextInputControl] opens
/// the touch keyboard automatically, which removes the need to start the on-screen keyboard by hand.
///
/// The keyboard is toggled through the `ITipInvocation` COM interface because starting `TabTip.exe`
/// does nothing when the legacy touch keyboard process is already running, which is the normal state
/// on Windows 11. Starting the executable is kept only as a fallback.
@NotNullByDefault
public final class TouchKeyboard {
    /// The `SM_MAXIMUMTOUCHES` system metric, which is greater than zero when touch input is available.
    private static final int SM_MAXIMUMTOUCHES = 95;

    /// The `CLSID_UIHostNoLaunch` class identifier of the touch keyboard host.
    private static final String UI_HOST_NO_LAUNCH_CLSID = "4CE576FA-83DC-4F88-951C-9D0782B4E376";

    /// The `IID_ITipInvocation` interface identifier of the touch keyboard invoker.
    private static final String TIP_INVOCATION_IID = "37C994E7-432B-4834-A2F7-DCE1F13B834B";

    /// The `CLSCTX_LOCAL_SERVER` activation context, which is the context registered for the touch keyboard host.
    private static final int CLSCTX_LOCAL_SERVER = 0x4;

    /// The `COINIT_APARTMENTTHREADED` COM initialization mode.
    private static final int COINIT_APARTMENTTHREADED = 0x2;

    /// The vtable index of `IUnknown::Release`.
    private static final int VTBL_RELEASE = 2;

    /// The vtable index of `ITipInvocation::Toggle`.
    private static final int VTBL_TOGGLE = 3;

    /// The minimum interval between two keyboard invocations.
    private static final long LAUNCH_COOLDOWN_NANOS = TimeUnit.MILLISECONDS.toNanos(1500);

    /// The time of the last keyboard invocation, in nanoseconds.
    private static long lastInvocationTime;

    /// Installs the touch keyboard handler on the given scene.
    ///
    /// Does nothing when the current system is not a touch-enabled Windows device.
    ///
    /// @param scene the scene whose text input controls should open the touch keyboard
    public static void install(Scene scene) {
        if (!isSupported()) {
            return;
        }

        scene.addEventFilter(MouseEvent.MOUSE_PRESSED, event -> {
            if (findEditableTextInput(event.getTarget()) != null) {
                requestKeyboard();
            }
        });

        LOG.info("Touch keyboard integration enabled");
    }

    /// Requests the touch keyboard, respecting the invocation cooldown.
    private static void requestKeyboard() {
        long now = System.nanoTime();
        if (now - lastInvocationTime < LAUNCH_COOLDOWN_NANOS) {
            return;
        }
        lastInvocationTime = now;

        Lang.thread(TouchKeyboard::showKeyboard, "Show touch keyboard", true);
    }

    /// Toggles the touch keyboard through COM, falling back to starting the keyboard process.
    private static void showKeyboard() {
        if (toggleWithCom()) {
            return;
        }

        @Nullable Path executable = findKeyboardExecutable();
        if (executable == null) {
            LOG.warning("Touch keyboard is not available");
            return;
        }

        try {
            new ProcessBuilder(executable.toString()).start();
        } catch (IOException e) {
            LOG.warning("Failed to start " + executable.getFileName(), e);
        }
    }

    /// Toggles the touch keyboard by activating the `ITipInvocation` COM object.
    ///
    /// @return `true` when the COM call succeeded
    private static boolean toggleWithCom() {
        @Nullable Ole32 ole32 = Ole32.INSTANCE;
        @Nullable User32 user32 = User32.INSTANCE;
        if (ole32 == null || user32 == null) {
            return false;
        }

        boolean comInitialized = false;
        try {
            if (ole32.CoInitializeEx(null, COINIT_APARTMENTTHREADED) < 0) {
                return false;
            }
            comInitialized = true;

            PointerByReference reference = new PointerByReference();
            int createResult = ole32.CoCreateInstance(guid(UI_HOST_NO_LAUNCH_CLSID), null,
                    CLSCTX_LOCAL_SERVER, guid(TIP_INVOCATION_IID), reference);
            if (createResult < 0) {
                LOG.warning("Failed to create the touch keyboard COM object, HRESULT=0x"
                        + Integer.toHexString(createResult));
                return false;
            }

            Pointer invocation = reference.getValue();
            if (invocation == null) {
                return false;
            }

            try {
                Pointer interfaceVtable = vtable(invocation);
                @Nullable Pointer foregroundWindow = user32.GetForegroundWindow();
                int toggleResult = invoke(interfaceVtable, VTBL_TOGGLE, invocation, foregroundWindow);
                if (toggleResult < 0) {
                    LOG.warning("Failed to toggle the touch keyboard, HRESULT=0x"
                            + Integer.toHexString(toggleResult));
                    return false;
                }
                return true;
            } finally {
                invoke(vtable(invocation), VTBL_RELEASE, invocation);
            }
        } catch (Throwable e) {
            LOG.warning("Failed to toggle the touch keyboard", e);
            return false;
        } finally {
            if (comInitialized) {
                ole32.CoUninitialize();
            }
        }
    }

    /// Calls a COM vtable method with the standard Windows calling convention.
    ///
    /// @param vtable the vtable of the COM object
    /// @param index the zero-based vtable index of the method
    /// @param arguments the method arguments, starting with the interface pointer
    /// @return the `HRESULT` returned by the method
    private static int invoke(Pointer vtable, int index, Object... arguments) {
        Pointer address = new Pointer(vtable.getLong((long) index * Native.POINTER_SIZE));
        return Function.getFunction(address, Function.ALT_CONVENTION).invokeInt(arguments);
    }

    /// Returns the vtable pointer of a COM interface.
    ///
    /// The vtable is read as a native integer because [Pointer#getPointer] returns a shifted value
    /// on 64-bit ARM builds of JNA.
    ///
    /// @param instance the COM interface pointer
    /// @return the vtable pointer
    private static Pointer vtable(Pointer instance) {
        return new Pointer(instance.getLong(0));
    }

    /// Creates a 16-byte native GUID from its textual representation.
    ///
    /// @param text the GUID in the `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` form
    /// @return the native GUID
    private static Memory guid(String text) {
        String[] parts = text.split("-");
        Memory memory = new Memory(16);
        memory.clear();
        memory.setInt(0, (int) Long.parseLong(parts[0], 16));
        memory.setShort(4, (short) Integer.parseInt(parts[1], 16));
        memory.setShort(6, (short) Integer.parseInt(parts[2], 16));
        for (int i = 0; i < 2; i++) {
            memory.setByte(8 + i, (byte) Integer.parseInt(parts[3].substring(i * 2, i * 2 + 2), 16));
        }
        for (int i = 0; i < 6; i++) {
            memory.setByte(10 + i, (byte) Integer.parseInt(parts[4].substring(i * 2, i * 2 + 2), 16));
        }
        return memory;
    }

    /// Finds the editable text input containing the given event target.
    ///
    /// @param target the event target node
    /// @return the editable text input, or `null` when the target is not inside one
    private static @Nullable TextInputControl findEditableTextInput(@Nullable Object target) {
        if (!(target instanceof Node node)) {
            return null;
        }

        while (node != null) {
            if (node instanceof TextInputControl input) {
                return !input.isDisabled() && input.isEditable() ? input : null;
            }
            node = node.getParent();
        }

        return null;
    }

    /// Checks whether the current system is Windows with touch input.
    ///
    /// @return `true` when the touch keyboard should be integrated
    private static boolean isSupported() {
        if (OperatingSystem.CURRENT_OS != OperatingSystem.WINDOWS) {
            return false;
        }

        @Nullable User32 user32 = User32.INSTANCE;
        if (user32 == null) {
            return false;
        }

        try {
            return user32.GetSystemMetrics(SM_MAXIMUMTOUCHES) > 0;
        } catch (Throwable e) {
            LOG.warning("Failed to detect touch input", e);
            return false;
        }
    }

    /// Locates the Windows touch keyboard executable.
    ///
    /// @return the executable path, or `null` when no on-screen keyboard is installed
    private static @Nullable Path findKeyboardExecutable() {
        @Nullable Path path = resolveTabTip(System.getenv("CommonProgramFiles"));
        if (path != null) {
            return path;
        }

        path = resolveTabTip(System.getenv("CommonProgramFiles(x86)"));
        if (path != null) {
            return path;
        }

        @Nullable String windir = System.getenv("WINDIR");
        if (windir != null) {
            Path fallback = Path.of(windir, "System32", "osk.exe");
            if (Files.isRegularFile(fallback)) {
                return fallback;
            }
        }

        return null;
    }

    /// Resolves `TabTip.exe` below the given common program files directory.
    ///
    /// @param commonProgramFiles the common program files directory, or `null` when unavailable
    /// @return the executable path, or `null` when it does not exist
    private static @Nullable Path resolveTabTip(@Nullable String commonProgramFiles) {
        if (commonProgramFiles == null || commonProgramFiles.isBlank()) {
            return null;
        }

        Path path = Path.of(commonProgramFiles, "microsoft shared", "ink", "TabTip.exe");
        return Files.isRegularFile(path) ? path : null;
    }

    /// Prevents instantiation.
    private TouchKeyboard() {
    }
}
