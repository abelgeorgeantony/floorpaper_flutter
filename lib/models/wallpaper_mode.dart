// TODO(scrolling-pages): The "Enable scrolling" / multi-page wallpaper
// feature is currently on hold. This enum is kept because `CurrentWallpaper`
// still reads and writes it for backward compatibility with older saved
// records. When the feature is reimplemented, restore the UI in
// `TilePreviewScreen` that lets the user pick between `singlePage` and
// `allPages` (and the pages slider that appears beneath it).
enum WallpaperMode { singlePage, allPages }