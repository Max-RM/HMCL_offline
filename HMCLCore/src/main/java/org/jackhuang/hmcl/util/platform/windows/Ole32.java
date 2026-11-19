// SPDX-FileCopyrightText: Copyright (C) 2026 The HMCL Authors
// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-HMCL
package org.jackhuang.hmcl.util.platform.windows;

import com.sun.jna.Pointer;
import com.sun.jna.ptr.PointerByReference;
import com.sun.jna.win32.StdCallLibrary;
import org.jackhuang.hmcl.util.platform.NativeUtils;
import org.jetbrains.annotations.NotNullByDefault;
import org.jetbrains.annotations.Nullable;

/// Provides the subset of the OLE32 functions used to activate in-process and local COM servers.
///
/// @author Glavo
@NotNullByDefault
public interface Ole32 extends StdCallLibrary {

    /// The loaded OLE32 library, or `null` when JNA is unavailable or the current platform is not Windows.
    @Nullable Ole32 INSTANCE = NativeUtils.USE_JNA && com.sun.jna.Platform.isWindows()
            ? NativeUtils.load("ole32", Ole32.class)
            : null;

    /// Initializes the COM library on the current thread.
    ///
    /// @param pvReserved reserved for future use; must be `null`
    /// @param dwCoInit the concurrency model and initialization options
    /// @return `S_OK`, `S_FALSE`, or a negative error code
    /// @see <a href="https://learn.microsoft.com/windows/win32/api/combaseapi/nf-combaseapi-coinitializeex">CoInitializeEx function</a>
    int CoInitializeEx(@Nullable Pointer pvReserved, int dwCoInit);

    /// Closes the COM library on the current thread.
    ///
    /// @see <a href="https://learn.microsoft.com/windows/win32/api/combaseapi/nf-combaseapi-couninitialize">CoUninitialize function</a>
    void CoUninitialize();

    /// Creates a single uninitialized object of the class associated with the specified CLSID.
    ///
    /// @param rclsid the CLSID of the object to create
    /// @param pUnkOuter the controlling `IUnknown`, or `null` when the object is not being aggregated
    /// @param dwClsContext the context in which the code that manages the newly created object runs
    /// @param riid the identifier of the interface to obtain
    /// @param ppv the address that receives the interface pointer
    /// @return `S_OK` or a negative error code
    /// @see <a href="https://learn.microsoft.com/windows/win32/api/combaseapi/nf-combaseapi-cocreateinstance">CoCreateInstance function</a>
    int CoCreateInstance(Pointer rclsid,
                         @Nullable Pointer pUnkOuter,
                         int dwClsContext,
                         Pointer riid,
                         PointerByReference ppv);
}
