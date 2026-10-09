import JavaIntelligence
import XCTest
@testable import Umbra

@MainActor
final class IDERunConfigurationsEditorTests: XCTestCase {
    private func app(_ name: String, file: String = "A") -> JavaRunConfiguration {
        JavaRunConfiguration(
            name: name, target: .classpathMain(className: "app.\(file)", sourceFile: "/p/\(file).java")
        )
    }

    private func editor(_ configurations: [JavaRunConfiguration] = [], highlighting: JavaRunConfiguration? = nil) -> IDERunConfigurationsEditor {
        var templates: [JavaRunConfiguration.Kind: JavaRunConfiguration] = [:]
        for kind in JavaRunConfiguration.Kind.allCases { templates[kind] = JavaRunConfiguration.defaultTemplate(for: kind) }
        return IDERunConfigurationsEditor(configurations: configurations, templates: templates, highlighting: highlighting)
    }

    func testLookingChangesNothing() {
        let editor = editor([app("A"), app("B", file: "B")])
        XCTAssertFalse(editor.hasChanges)
        XCTAssertEqual(editor.selectedConfigurationID, editor.configurations.last?.id, "the newest is selected")
        editor.selection = .configuration(editor.configurations[0].id)
        XCTAssertFalse(editor.hasChanges)
    }

    func testEditingOneConfigurationSavesOnlyThatOne() {
        let editor = editor([app("A"), app("B", file: "B")])
        editor.selection = .configuration(editor.configurations[0].id)
        editor.selected?.programArguments = "--port 80"
        XCTAssertTrue(editor.isChanged(editor.configurations[0].id))
        XCTAssertFalse(editor.isChanged(editor.configurations[1].id))
        let changes = editor.changes()
        XCTAssertEqual(changes.saved.map(\.displayName), ["A"])
        XCTAssertEqual(changes.saved.first?.programArguments, "--port 80")
        XCTAssertTrue(changes.deleted.isEmpty)
        XCTAssertTrue(changes.templates.isEmpty)
    }

    func testAddingStartsFromTheKindsTemplateAndPicksAFreshName() {
        let editor = editor([app("Application")])
        var template = JavaRunConfiguration.defaultTemplate(for: .application)
        template.vmArguments = "-Xmx2g"
        template.buildBeforeRun = false
        editor.selection = .template(.application)
        editor.selected = template
        let added = editor.add(kind: .application, target: .classpathMain(className: "app.New", sourceFile: "/p/New.java"))
        XCTAssertEqual(added.vmArguments, "-Xmx2g")
        XCTAssertFalse(added.buildBeforeRun)
        XCTAssertEqual(added.displayName, "Application 2")
        XCTAssertEqual(editor.selectedConfigurationID, added.id)
        XCTAssertTrue(editor.isNew(added.id))
        let changes = editor.changes()
        XCTAssertEqual(changes.saved.map(\.id), [added.id])
        XCTAssertEqual(changes.templates.map(\.kind), [.application])
        XCTAssertEqual(changes.templates.first?.vmArguments, "-Xmx2g")
    }

    func testRemovingDeletesItAndSelectsANeighbour() {
        let a = app("A"), b = app("B", file: "B"), c = app("C", file: "C")
        let editor = editor([a, b, c])
        editor.selection = .configuration(b.id)
        editor.remove(b.id)
        XCTAssertEqual(editor.configurations.map(\.id), [a.id, c.id])
        XCTAssertEqual(editor.selectedConfigurationID, c.id)
        XCTAssertEqual(editor.changes().deleted, [b.id])
        editor.remove(c.id)
        XCTAssertEqual(editor.selectedConfigurationID, a.id)
    }

    func testRemovingOneDropsItFromWhatRunsBefore() {
        let a = app("A")
        var b = app("B", file: "B")
        b.beforeLaunch = [.gradleTasks(["x"]), .runConfiguration(a.id)]
        let editor = editor([a, b])
        editor.remove(a.id)
        XCTAssertEqual(editor.configurations[0].beforeLaunch, [.gradleTasks(["x"])])
        XCTAssertEqual(editor.changes().saved.map(\.id), [b.id], "the one that waited on it is rewritten")
    }

    func testDuplicateSitsNextToTheOriginalWithANewIdentity() {
        let a = app("A"), b = app("B", file: "B")
        let editor = editor([a, b])
        let copy = editor.duplicate(a.id)
        XCTAssertEqual(editor.configurations.map(\.id), [a.id, copy!.id, b.id])
        XCTAssertEqual(copy?.name, "A copy")
        XCTAssertNotEqual(copy?.id, a.id)
        XCTAssertEqual(editor.selectedConfigurationID, copy?.id)
        XCTAssertEqual(editor.duplicate(a.id)?.name, "A copy 2")
    }

    func testKeepingATemporaryConfigurationSavesItWithoutAnEdit() {
        var temporary = app("")
        temporary.name = nil
        temporary.isTemporary = true
        let editor = editor([temporary])
        XCTAssertFalse(editor.hasChanges)
        editor.keep(temporary.id)
        XCTAssertFalse(editor.isChanged(temporary.id), "keeping is not an edit of its settings")
        let changes = editor.changes()
        XCTAssertEqual(changes.saved.map(\.id), [temporary.id])
        XCTAssertEqual(changes.saved.first?.isTemporary, false)
    }

    func testOpeningOnADraftSelectsItAndKeepsIt() {
        var draft = app("")
        draft.name = nil
        draft.isTemporary = true
        let editor = editor([app("A")], highlighting: draft)
        XCTAssertEqual(editor.selectedConfigurationID, draft.id)
        XCTAssertTrue(editor.isNew(draft.id))
        XCTAssertEqual(editor.changes().saved.map(\.id), [draft.id])

        // A saved temporary configuration opened for editing is kept by OK.
        var saved = app("")
        saved.name = nil
        saved.isTemporary = true
        let again = self.editor([saved], highlighting: saved)
        XCTAssertFalse(again.isNew(saved.id))
        XCTAssertEqual(again.changes().saved.map(\.id), [saved.id])
        XCTAssertEqual(again.changes().saved.first?.isTemporary, false)
    }

    func testGroupsByKindThenFolder() {
        var a = app("A"), b = app("B", file: "B"), c = app("C", file: "C")
        a.folder = "Servers"
        b.folder = nil
        c.folder = "Servers"
        let file = JavaRunConfiguration(name: "F", target: .singleFile(path: "/p/F.java"))
        let editor = editor([a, b, c, file])
        let groups = editor.groups(of: .application)
        XCTAssertEqual(groups.map(\.folder), [nil, "Servers"])
        XCTAssertEqual(groups[0].configurations.map(\.displayName), ["B"])
        XCTAssertEqual(groups[1].configurations.map(\.displayName), ["A", "C"])
        XCTAssertEqual(editor.groups(of: .javaFile).count, 1)
        XCTAssertTrue(editor.groups(of: .junit).isEmpty)

        editor.move(b.id, toFolder: " Servers ")
        XCTAssertEqual(editor.groups(of: .application).map(\.folder), ["Servers"])
        editor.move(b.id, toFolder: nil)
        XCTAssertEqual(editor.groups(of: .application).map(\.folder), [nil, "Servers"])
    }

    func testApplyingResetsWhatCountsAsChanged() {
        let editor = editor([app("A")])
        editor.selected?.programArguments = "x"
        XCTAssertTrue(editor.hasChanges)
        editor.markApplied()
        XCTAssertFalse(editor.hasChanges)
        editor.selected?.programArguments = "y"
        XCTAssertEqual(editor.changes().saved.first?.programArguments, "y")
    }

    func testEditingTheTemplateAndResettingIt() {
        let editor = editor()
        editor.selection = .template(.javaFile)
        XCTAssertEqual(editor.selected?.kind, .javaFile)
        editor.selected?.vmArguments = "-ea"
        XCTAssertEqual(editor.changes().templates.first?.vmArguments, "-ea")
        editor.resetTemplate(.javaFile)
        XCTAssertFalse(editor.hasChanges)
    }
}
