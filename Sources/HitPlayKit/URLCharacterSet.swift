import Foundation

extension CharacterSet {
    /// 播放地址补编码用：URL 各区段合法字符的并集（含 % 本身，已有的 %XX 不会被二次编码）。
    public static let urlAllowed: CharacterSet = {
        var set = CharacterSet.urlHostAllowed
        set.formUnion(.urlPathAllowed)
        set.formUnion(.urlQueryAllowed)
        set.formUnion(.urlFragmentAllowed)
        set.formUnion(.alphanumerics)
        set.formUnion(CharacterSet(charactersIn: "-._~!$&'()*+,;=:@/?#[]%"))
        return set
    }()
}
