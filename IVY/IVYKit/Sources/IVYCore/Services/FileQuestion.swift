import Foundation

/// The question IVY asks itself when you choose "Ask IVY about this file" on the shelf.
/// The file's details travel separately as attached context.
public enum FileQuestion {
    public static func prompt(fileName: String) -> String {
        "Briefly describe the attached file \u{201C}\(fileName)\u{201D}: what it is and what it shows or contains."
    }

    /// A question typed during a file chat. Ties it to the file so "the progress bar" or
    /// "the text" isn't mistaken for the music player or the clipboard; actions still work.
    public static func followUp(_ question: String, fileName: String) -> String {
        "About the attached file \u{201C}\(fileName)\u{201D} described earlier in this conversation (answer from its details "
            + "unless I clearly ask you to do something else): \(question)"
    }

    /// Guidance placed in front of on-device image analysis, which is label-based: the model
    /// should describe the likely content without claiming to have seen the pixels.
    public static let imageGuidance = """
    The file is an image. IVY can't see images directly; below is Apple Vision's on-device analysis \
    (scene labels with confidence, text found in the image, people, animals and codes). Describe what the \
    image most likely shows from these clues, mention any text it contains, and say so when you're unsure.
    """
}
