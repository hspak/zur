pub const Esc = "\x1B";
pub const Csi = Esc ++ "[";
pub const Reset = Csi ++ "0m";

pub const Bold = Csi ++ "1m";
pub const ForegroundGreen = Csi ++ "32m";
pub const ForegroundRed = Csi ++ "31m";
pub const ForegroundYellow = Csi ++ "33m";
pub const ForegroundBlue = Csi ++ "34m";
pub const ForegroundMagenta = Csi ++ "35m";
pub const ForegroundCyan = Csi ++ "36m";

pub const BoldForegroundBlue = Bold ++ ForegroundBlue;
pub const BoldForegroundYellow = Bold ++ ForegroundYellow;
pub const BoldForegroundGreen = Bold ++ ForegroundGreen;
pub const BoldForegroundMagenta = Bold ++ ForegroundMagenta;
pub const BoldForegroundCyan = Bold ++ ForegroundCyan;
