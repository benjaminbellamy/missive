// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // A short how-to shown from the main menu.
    [GtkTemplate (ui = "/fr/bellamy/missive/help-dialog.ui")]
    public class HelpDialog : Adw.Dialog {
        public HelpDialog () {
            Object ();
        }
    }
}
