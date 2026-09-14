import Foundation

@main struct ModelChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CGLauncherModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedAccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try store.rememberVerifiedLogin(username: "demoAlpha", password: "alphaPassword", regionID: 33)
        try store.rememberVerifiedLogin(username: "demoBeta", password: "betaPassword", regionID: 36)
        let model = LauncherModel(accountStore: store)
        precondition(model.savedAccounts.count == 2)
        precondition(model.username == "demoBeta" && model.password == "betaPassword" && model.regionID == 36)
        let game = GameAccount(id: "synthetic", status: 0, entitlement: 0, restriction: 0)
        model.session = AuthenticatedSession(accounts: [game], authenticatedAt: Date(), token: Array("TEST".utf8), serverStamp: 1, endpoint: nil)
        model.accountID = game.id
        precondition(model.canLaunch)
        model.selectSavedAccount("demoAlpha")
        precondition(model.username == "demoAlpha" && model.password == "alphaPassword" && model.regionID == 33)
        precondition(model.session == nil && model.accountID.isEmpty && !model.canLaunch)
        model.editUsername("differentAccount")
        precondition(model.password.isEmpty && model.selectedSavedAccount.isEmpty)
        model.selectSavedAccount("demoBeta")
        precondition(model.password == "betaPassword")
        model.editPassword("notYetVerified")
        let unchanged = try store.load()
        precondition(unchanged.accounts.first(where: { $0.username == "demoBeta" })?.password == "betaPassword")
        model.selectSavedAccount("")
        precondition(model.username.isEmpty && model.password.isEmpty && model.session == nil)
        let reopened = LauncherModel(accountStore: store)
        precondition(reopened.username == "demoBeta" && reopened.password == "betaPassword")
        print("ACCOUNT_MODEL_CHECKS_OK restore switch clear_stale_session preserve_verified_password")
    }
}
