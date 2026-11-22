WAYLOCK(1) "https://codeberg.org/ifreund/waylock" "General Commands Manual"

# NAME

waylock - a small Wayland screenlocker

# SYNOPSIS

*waylock* [_options_]

# DESCRIPTION

Waylock is a small screenlocker for Wayland compositors implementing
*ext-session-lock-v1*. The *ext-session-lock-v1* protocol is significantly
more robust than previous client-side Wayland screen locking approaches.
Importantly, the screenlocker crashing does not cause the session to be
unlocked.

# OPTIONS

*-h*
	Print a help message and exit.

*-version*
	Print the version number and exit.

*-log-level* [*error*|*warning*|*info*|*debug*]
	Set the log level of waylock. At the *error* log level, only errors
	are logged.  At the *debug* log level, everything is logged including
	verbose debug messages.

*-fork-on-lock*
	Fork to the background after locking the session. This is useful to
	integrate with idle management daemons without racing to lock the
	session before suspend. With this option waylock will exit once the
	session has been locked and it is safe to suspend.

*-ready-fd* _fd_
	Write a newline to file descriptor _fd_ (a number) after locking and
	close the _fd_. This is useful if a fork-less lock notification is needed;
	for example, for integration with a service manager.

*-ignore-empty-password*
	Do not submit empty passwords to PAM for validation when the Enter
	key is pressed. Instead, do nothing. This may be useful if, for
	example, the Enter key is used to wake the computer from sleep.

*-config* _path_
	Read theme and geometry from _path_. The default is
	*$XDG_CONFIG_HOME/waylock/theme.conf*. See *examples/theme.conf* for
	a complete example.

*-pam-service* _name_
	Use the named PAM service. (default: waylock)

*-init-color* _0xRRGGBB_
	Set the fallback background color used when no theme file is loaded.
	(default: 0x002b36)

*-input-color* _0xRRGGBB_
	Set the fallback primary color used when no theme file is loaded.
	(default: 0x6c71c4)

*-fail-color* _0xRRGGBB_
	Set the fallback error color used when no theme file is loaded.
	(default: 0xdc322f)

# CONFIGURATION

The theme file uses one `key = value` pair per line. Global keys must come
before the first `[widget.NAME]` section. Use a `[global]` section to switch
back to global keys after a widget section.

Global keys include `background_image`, `background_color`, `surface_color`, `surface_opacity`, `text_color`, `primary_color`, `error_color`, `outline_color`, `box_width`, `box_height`, `border_radius`, `box_anchor`, `box_x`, `box_y`, `dot_spacing`, `dot_radius`, `font_family`, `font_size`, `fade_ms`, and `compositor_fade`.

The `compositor_fade = auto` setting enables the transparent crossfade when the compositor keeps the live desktop visible below the lock surface. The SwayFX `session_lock_xray` patch in `contrib/` does this and exports `SWAYFX_SESSION_LOCK_XRAY=1`. Set it to `true` or `false` to force the behavior. Without compositor support, only the UI fades over the blurred wallpaper.

The password field and every widget are positioned relative to an anchor:

```
box_anchor = center
box_x = 0
box_y = 0
```

Valid anchors are `top-left`, `top-center`, `top-right`, `center-left`, `center`, `center-right`, `bottom-left`, `bottom-center`, and `bottom-right`. The `x` and `y` values are pixel offsets from that anchor; positive values move right and down.

A widget section adds a text or image element:

```
[widget.hostname]
type = text
text = legion
anchor = top-center
x = 0
y = 40
font_size = 18
color = #e4e2e4
```

Widget keys include `type` (`text` or `image`), `text`, `image`, `anchor`, `x`, `y`, `font_family`, `font_size`, `bold`, `color`, `opacity`, `width`, and `height`. The `width` and `height` keys apply to image widgets; text is sized by `font_size`. Up to 32 widgets may be defined.

# USAGE

Run the waylock executable to lock the session. Each monitor shows the
configured background image, with a single password field. Typing causes the
field's outline to animate to the primary color and adds a fading dot for
every codepoint. Esc or Ctrl-U clears all current input, while backspace
deletes the last UTF-8 codepoint.

The lock screen fades in when the session is locked and fades out before it
is unlocked. With compositor support, this is a true crossfade from and back
to the live desktop. Otherwise, only the UI fades over the blurred wallpaper.
Set `fade_ms = 0` to disable the transition.

To unlock the session, type your password and press Enter. If the password
is correct, waylock will unlock the session and exit. Otherwise, the field's
outline animates to the error color and you may try again.

In order to automatically run waylock after a certain amount of time with
no input or before sleep, the *swayidle*(1) utility or a similar program
may be used. See the *swayidle*(1) man page for details.

# AUTHORS

Maintained by Isaac Freund <mail@isaacfreund.com> who is assisted by open
source contributors. For more information about waylock's development, see
https://codeberg.org/ifreund/waylock.

# SEE ALSO

*pam*(8), *swayidle*(1)
