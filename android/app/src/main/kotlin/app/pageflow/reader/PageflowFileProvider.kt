package app.pageflow.reader

import androidx.core.content.FileProvider

// A distinct provider keeps sharing separate from the annotation plugin's
// provider, preserving both authorities and their file-path configurations.
class PageflowFileProvider : FileProvider()

