public enum DefaultConfig {
    public static let text = #"""
# panespace config — i3 syntax. Lives at ~/.config/panespace/config
# Reload with $mod+Shift+c (or `panespace msg reload`).
#
# Modifiers: alt (Mod1), cmd (Mod4/super), ctrl, shift, hyper (all four), meh (ctrl+alt+shift)
# Criteria:  [app="regex"] [bundle_id="regex"] [title="regex"] [floating] [tiling]
#            (i3's class/instance are accepted as aliases of app)
# Find names for rules with: panespace list-windows

# ctrl+alt (⌃⌥) is free in almost every Mac app. Plain alt would steal app shortcuts and the
# special characters alt types (∑, †, …). Or make Caps Lock the panespace key, no other app needed:
#   set $mod caps
set $mod ctrl+alt

# ── Look ────────────────────────────────────────────────
gaps inner 8
gaps outer 8
smart_gaps off
accordion_padding 30          # how much of neighbouring windows peeks out in tabbed/stacking
default_orientation auto      # horizontal on landscape monitors, vertical on portrait
workspace_indicator number    # menu bar, current workspace: number | pill | panes | circle | minimal; all: segmented | dots | tiles
default_border none           # "default_border pixel 2" draws an i3-style outline around the focused window
border_radius 12
#                 border  bg      text    indicator child_border
client.focused    #5294e2 #5294e2 #ffffff #5294e2   #5294e2

# ── Behaviour ───────────────────────────────────────────
workspace_auto_back_and_forth no
focus_wrapping yes
mouse_warping output          # move the mouse along when focus jumps to another monitor
floating_modifier $mod        # hold it and drag: left = move, right = resize. Drop a tiled window on another to swap.
focus_follows_mouse no
smooth_layout yes             # workspace switches without a flash of empty desktop
animations yes                # windows glide when the layout changes
animation_duration 180        # milliseconds until a move looks finished (it moves on a spring)

# ── Launch ──────────────────────────────────────────────
# Pick your terminal: open -na Ghostty | open -na kitty | open -na Alacritty | open -na iTerm
bindsym $mod+Return exec osascript -e 'tell application "Terminal" to do script ""' -e 'tell application "Terminal" to activate'
bindsym $mod+Shift+q kill

# ── Focus ───────────────────────────────────────────────
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left focus left
bindsym $mod+Down focus down
bindsym $mod+Up focus up
bindsym $mod+Right focus right
bindsym $mod+a focus parent
bindsym $mod+Shift+a focus child
bindsym $mod+space focus mode_toggle
bindsym $mod+slash switcher               # search every window by app or title

# ── Move ────────────────────────────────────────────────
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left move left
bindsym $mod+Shift+Down move down
bindsym $mod+Shift+Up move up
bindsym $mod+Shift+Right move right

# ── Layout ──────────────────────────────────────────────
bindsym $mod+b split h
bindsym $mod+v split v
bindsym $mod+e layout toggle split
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+f fullscreen toggle
# Apps' own full screen (a video's fullscreen button, a game's fullscreen mode) works as usual: the window
# leaves the layout while it's full screen and comes back to its tile after. The green button, ⌃⌘F and Globe+F
# use panespace fullscreen instead, which keeps the window tiled. "native_fullscreen macos" turns that off.
native_fullscreen panespace
# Immersive (Omarchy-style): auto-hide the macOS menu bar so tiles and fullscreen use the whole display.
# The Dock follows its own macOS setting. Toggle with $mod+Shift+f. "immersive yes" starts in it;
# "immersive no" always starts with the menu bar shown; leave it unset to never change it at launch.
bindsym $mod+Shift+f immersive toggle
bindsym $mod+Shift+space floating toggle
bindsym $mod+Shift+equal balance

# ── Scratchpad ──────────────────────────────────────────
bindsym $mod+Shift+minus move scratchpad
bindsym $mod+minus scratchpad show

# ── Workspaces ──────────────────────────────────────────
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+6 workspace number 6
bindsym $mod+7 workspace number 7
bindsym $mod+8 workspace number 8
bindsym $mod+9 workspace number 9
bindsym $mod+0 workspace number 10

bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5
bindsym $mod+Shift+6 move container to workspace number 6
bindsym $mod+Shift+7 move container to workspace number 7
bindsym $mod+Shift+8 move container to workspace number 8
bindsym $mod+Shift+9 move container to workspace number 9
bindsym $mod+Shift+0 move container to workspace number 10

bindsym $mod+Tab workspace back_and_forth
bindsym $mod+bracketright workspace next_on_output
bindsym $mod+bracketleft workspace prev_on_output
bindsym $mod+Shift+period move workspace to output next

# Pin workspaces to monitors (primary, secondary, 1, 2, or part of the display name):
# workspace 9 output secondary primary

# ── Session ─────────────────────────────────────────────
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exit

# ── Resize mode ─────────────────────────────────────────
bindsym $mod+r mode "resize"
mode "resize" {
    bindsym h resize shrink width 50 px or 5 ppt
    bindsym j resize grow height 50 px or 5 ppt
    bindsym k resize shrink height 50 px or 5 ppt
    bindsym l resize grow width 50 px or 5 ppt
    bindsym Left resize shrink width 50 px or 5 ppt
    bindsym Down resize grow height 50 px or 5 ppt
    bindsym Up resize shrink height 50 px or 5 ppt
    bindsym Right resize grow width 50 px or 5 ppt
    bindsym b balance
    bindsym Return mode "default"
    bindsym Escape mode "default"
    bindsym $mod+r mode "default"
}

# ── Rules ───────────────────────────────────────────────
for_window [app="^(System Settings|System Preferences|Calculator|Archive Utility|Installer|Software Update|Photo Booth|QuickTime Player)$"] floating enable
for_window [app="^Finder$" title="^(Copy|Move|Delete|Connect to Server|.* Info)$"] floating enable
# assign [app="^Slack$"] 9
# for_window [app="^Spotify$"] move container to workspace number 8
"""#
}
