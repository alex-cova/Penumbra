import Foundation

/// Members brought into scope by `import static` declarations: `import static a.B.name;` offers
/// `B`'s static members called `name`, `import static a.B.*;` every static member of `B`.
public enum JavaStaticImports {
    public static func members(context: JavaResolutionContext, index: JavaIndex) async -> [JavaResolvedMember] {
        var result: [JavaResolvedMember] = []
        for declaration in context.imports where declaration.isStatic {
            let owner: String
            let memberName: String?
            if declaration.isOnDemand {
                owner = declaration.qualifiedName
                memberName = nil
            } else {
                guard let dot = declaration.qualifiedName.lastIndex(of: ".") else { continue }
                owner = String(declaration.qualifiedName[..<dot])
                memberName = String(declaration.qualifiedName[declaration.qualifiedName.index(after: dot)...])
            }
            guard await index.classStub(qualifiedName: owner) != nil else { continue }
            let type = JavaTypeRef.classType(qualifiedName: owner, arguments: [], outer: nil)
            for member in await JavaMemberLookup.members(of: type, mode: .staticOnly, context: context, index: index)
            where memberName == nil || member.name == memberName {
                result.append(member)
            }
        }
        return result
    }
}
