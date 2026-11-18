// tgsample: the instrument maker without its window, for testing on the Mac.
import Foundation
import TuneGodSamplerKit

FileHandle.standardError.write(Data("usage: tgsample list | tgsample make \"<plugin>\" <out.tgi>\n".utf8))
exit(2)
