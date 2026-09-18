import Foundation

/// Small suppression lists, not a language dictionary. Membership never establishes a name.
enum CorrectionStopwords {
  static let functionWords: Set<String> = Set(
    "the a an and or but is are was were be been being to of in on for with this that it he she we they i you me him her us them my your our their its as at by from not no do does did have has had will would can could should if then than so a aj ale alebo je sú som si sme ste na do od z zo v vo pre pri že to ten tá tie ja ty my vy bol bola boli bolo byť sa čo ako keď nie áno už ešte len ho ich nás vás ktorý ktorá"
      .split(separator: " ").map(String.init))

  static let commonWords: Set<String> = functionWords.union(
    "today tomorrow yesterday good bad server servers computer computers monday tuesday wednesday thursday friday saturday sunday please send sent hello world now later run ran running walk walked walking work worked working go goes went gone make made get got say said new old first last next time day week month year dnes zajtra včera dobrý zlý servera serveru serverom servery urobiť urobil urobila robiť robil prosím poslať poslal deň čas nový starý pondelok utorok"
      .split(separator: " ")
      .map(String.init))
}
