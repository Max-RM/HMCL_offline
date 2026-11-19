// SPDX-FileCopyrightText: Copyright (C) 2026 The HMCL Authors
// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-HMCL
package org.jackhuang.hmcl.util;

import org.jackhuang.hmcl.Metadata;
import org.jetbrains.annotations.NotNullByDefault;
import org.jetbrains.annotations.Nullable;

import javax.imageio.ImageIO;
import javax.swing.BorderFactory;
import javax.swing.JPanel;
import javax.swing.JProgressBar;
import javax.swing.JWindow;
import javax.swing.SwingUtilities;
import java.awt.BorderLayout;
import java.awt.Color;
import java.awt.Dimension;
import java.awt.Font;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.GraphicsEnvironment;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.InputStream;

import static org.jackhuang.hmcl.util.i18n.I18n.i18n;
import static org.jackhuang.hmcl.util.logging.Logger.LOG;

/// Displays a lightweight splash window during launcher startup.
///
/// The window is implemented with Swing so that it can appear before the JavaFX toolkit and the
/// launcher UI are initialized. It should be hidden through [#close()] once the main stage is shown.
@NotNullByDefault
public final class SplashWindow {
    /// The splash background colour.
    private static final Color BACKGROUND = new Color(0x1E1E1E);

    /// The primary text colour.
    private static final Color FOREGROUND = new Color(0xF5F5F5);

    /// The secondary text colour.
    private static final Color SECONDARY = new Color(0xA8A8A8);

    /// The border colour.
    private static final Color BORDER = new Color(0x3A3A3A);

    /// The splash width in logical pixels.
    private static final int WIDTH = 480;

    /// The splash height in logical pixels.
    private static final int HEIGHT = 220;

    /// Guards [#window].
    private static final Object LOCK = new Object();

    /// The visible splash window, or `null` when no splash is shown.
    private static @Nullable JWindow window;

    /// The current startup status text, initially in the default locale.
    ///
    /// The splash is created before the launcher settings are loaded, so the language chosen by
    /// the user is only known later and can be applied through [#setStatus(String)].
    private static volatile String statusText = i18n("launcher.starting");

    /// Updates the startup status text shown by the splash window.
    ///
    /// Safe to call from any thread. The text is taken from the launcher language only after
    /// `SettingsManager` has been initialized.
    ///
    /// @param text the new status text, which must not be `null`
    public static void setStatus(String text) {
        statusText = text;

        @Nullable JWindow currentWindow;
        synchronized (LOCK) {
            currentWindow = window;
        }

        if (currentWindow != null) {
            SwingUtilities.invokeLater(currentWindow::repaint);
        }
    }

    /// Shows the splash window unless it is already visible.
    ///
    /// Does nothing in headless environments. All Swing work runs on the event dispatch thread.
    public static void show() {
        if (GraphicsEnvironment.isHeadless()) {
            return;
        }

        if (SwingUtilities.isEventDispatchThread()) {
            createAndShow();
            return;
        }

        try {
            SwingUtilities.invokeAndWait(SplashWindow::createAndShow);
        } catch (Throwable e) {
            LOG.warning("Failed to show splash window", e);
        }
    }

    /// Closes the splash window when it is visible.
    ///
    /// Safe to call from any thread and multiple times. Does nothing while the splash is disabled,
    /// so the Swing event dispatch thread is not started unnecessarily.
    public static void close() {
        @Nullable JWindow currentWindow;
        synchronized (LOCK) {
            currentWindow = window;
        }

        if (currentWindow == null) {
            return;
        }

        if (SwingUtilities.isEventDispatchThread()) {
            dispose();
            return;
        }

        try {
            SwingUtilities.invokeAndWait(SplashWindow::dispose);
        } catch (Throwable e) {
            LOG.warning("Failed to close splash window", e);
        }
    }

    /// Creates and shows the splash window on the event dispatch thread.
    private static void createAndShow() {
        synchronized (LOCK) {
            if (window != null) {
                return;
            }

            JWindow newWindow = new JWindow();
            newWindow.setContentPane(new SplashPanel(loadIcon()));
            newWindow.getRootPane().setBorder(BorderFactory.createLineBorder(BORDER));
            newWindow.pack();
            newWindow.setLocationRelativeTo(null);
            newWindow.setFocusableWindowState(false);

            // The splash must be visible even when the launcher is started from a foreground
            // terminal or explorer window, so it is raised above other top-level windows.
            newWindow.setAlwaysOnTop(true);
            newWindow.setVisible(true);
            newWindow.toFront();
            window = newWindow;
        }
    }

    /// Disposes the splash window on the event dispatch thread.
    private static void dispose() {
        @Nullable JWindow oldWindow;
        synchronized (LOCK) {
            oldWindow = window;
            window = null;
        }

        if (oldWindow != null) {
            oldWindow.dispose();
        }
    }

    /// Loads the launcher icon.
    ///
    /// @return the icon, or `null` when the resource is unavailable
    private static @Nullable BufferedImage loadIcon() {
        try (InputStream input = SplashWindow.class.getResourceAsStream("/assets/img/icon@4x.png")) {
            return input != null ? ImageIO.read(input) : null;
        } catch (Exception e) {
            LOG.warning("Failed to load splash icon", e);
            return null;
        }
    }

    /// Draws the splash icon, launcher name, version and startup status.
    @NotNullByDefault
    private static final class SplashPanel extends JPanel {
        /// The launcher icon, or `null` when unavailable.
        private final @Nullable BufferedImage icon;

        /// Creates a splash panel.
        ///
        /// @param icon the launcher icon, or `null` when unavailable
        SplashPanel(@Nullable BufferedImage icon) {
            this.icon = icon;
            setOpaque(true);
            setBackground(BACKGROUND);
            setPreferredSize(new Dimension(WIDTH, HEIGHT));
            setLayout(new BorderLayout());

            // The indeterminate bar animates on the event dispatch thread, which stays responsive
            // while the launcher initializes on the main thread.
            JProgressBar progressBar = new JProgressBar();
            progressBar.setIndeterminate(true);
            progressBar.setBorderPainted(false);
            progressBar.setOpaque(false);
            progressBar.setForeground(new Color(0x4C9AFF));
            progressBar.setPreferredSize(new Dimension(WIDTH, 4));
            add(progressBar, BorderLayout.SOUTH);
        }

        /// Paints the splash content.
        @Override
        protected void paintComponent(Graphics graphics) {
            super.paintComponent(graphics);

            Graphics2D g = (Graphics2D) graphics.create();
            try {
                g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
                g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);

                int iconSize = 72;
                int padding = 28;
                int centerY = getHeight() / 2;

                if (icon != null) {
                    g.drawImage(icon, padding, centerY - iconSize / 2, iconSize, iconSize, null);
                }

                int textX = icon != null ? padding + iconSize + 20 : padding;

                g.setColor(FOREGROUND);
                g.setFont(new Font(Font.SANS_SERIF, Font.BOLD, 20));
                g.drawString(Metadata.FULL_NAME, textX, centerY - 10);

                g.setColor(SECONDARY);
                g.setFont(new Font(Font.SANS_SERIF, Font.PLAIN, 12));
                g.drawString(Metadata.TITLE, textX, centerY + 12);
                g.drawString(statusText, textX, centerY + 34);
            } finally {
                g.dispose();
            }
        }
    }

    /// Prevents instantiation.
    private SplashWindow() {
    }
}
