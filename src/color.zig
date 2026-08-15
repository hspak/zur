pub const esc = "\x1B";
pub const csi = esc ++ "[";
pub const reset = csi ++ "0m";

pub const bold = csi ++ "1m";
pub const foreground_green = csi ++ "32m";
pub const foreground_red = csi ++ "31m";
pub const foreground_yellow = csi ++ "33m";
pub const foreground_blue = csi ++ "34m";
pub const foreground_magenta = csi ++ "35m";
pub const foreground_cyan = csi ++ "36m";

pub const bold_foreground_blue = bold ++ foreground_blue;
pub const bold_foreground_yellow = bold ++ foreground_yellow;
pub const bold_foreground_green = bold ++ foreground_green;
pub const bold_foreground_magenta = bold ++ foreground_magenta;
pub const bold_foreground_cyan = bold ++ foreground_cyan;
