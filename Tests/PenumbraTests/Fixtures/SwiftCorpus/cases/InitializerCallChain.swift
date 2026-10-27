struct Point { var x = 0; var y = 0; func length() -> Double { 0 } }
Point(x: 1, y: 2)./*|*/
//! contains: x, y, length
