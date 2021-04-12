pub const Esc = "\x1B";
pub const Csi = Esc ++ "[";
pub const Reset = Csi ++ "0m";

pub const Bold = Csi ++ "1m";
pub const ForegroundGreen = Csi ++ "32m";
pub const ForegroundRed = Csi ++ "31m";
pub const ForegroundBlue = Csi ++ "34m";

pub const BoldForegroundBlue = Bold ++ ForegroundBlue;
