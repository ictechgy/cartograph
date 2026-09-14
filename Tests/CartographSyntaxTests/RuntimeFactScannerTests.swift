import CartographCore
@testable import CartographSyntax
import Testing

@Suite("Swift 런타임 경계 스캐너")
struct RuntimeFactScannerTests {
    @Test("Swift closure action을 미지원 Objective-C selector 등록으로 세지 않는다")
    func closureActionsAreNotSelectorRegistrations() {
        let facts = scan("""
            func install() {
                Button(action: { print("pressed") })
                customRegistry(action: Selector("receive:"))
            }
            """)
        #expect(facts.limitations.contains {
            $0 == "Selector registration calls using APIs outside the supported runtime registry: 1."
        })
        #expect(!facts.limitations.contains { $0.hasSuffix("registry: 2.") })
    }

    @Test("selector 선언 타입을 nil 또는 미상 수신자로 바꿔치기하지 않는다")
    func selectorDeclaringTypeDoesNotInventReceiver() {
        let facts = scan("""
            class Other: NSObject { @objc func open() {} }
            class Actual: NSObject {
                func wire(button: UIControl, unknown: AnyObject) {
                    button.addTarget(nil, action: #selector(Other.open), for: .touchUpInside)
                    unknown.perform(#selector(Other.open))
                    perform(#selector(Other.open))
                }
            }
            """)
        let registration = facts.boundaries.first { $0.kind == .selectorRegistration }
        #expect(registration?.receiverTypeName == nil)
        let invocations = facts.boundaries.filter { $0.kind == .selectorInvocation }
        #expect(invocations.count == 2)
        #expect(invocations[0].receiverTypeName != "Other")
        #expect(invocations[1].receiverTypeName == "Actual")
    }

    @Test("묵시적 ObjC 노출의 generic tuple nonobjc 선언과 기본 클래스 이름은 추측하지 않는다")
    func implicitObjectiveCNamesAreConservative() {
        let facts = scan("""
            @objc class DefaultNamed: NSObject {}
            @objcMembers class Implicit: NSObject {
                func generic<T>(_ value: T) {}
                func tuple(_ value: (Int, Int)) {}
                @nonobjc func hidden() {}
                func plain() {}
            }
            """)
        #expect(facts.declarations.first { $0.name == "DefaultNamed" }?.objectiveCName == nil)
        for name in ["generic", "tuple", "hidden"] {
            #expect(facts.declarations.first { $0.name == name }?.objectiveCName == nil)
        }
        #expect(facts.declarations.first { $0.name == "plain" }?.objectiveCName == "plain")
    }

    private let path = "/p/Runtime.swift"

    private func scan(_ source: String) -> RuntimeFileFacts {
        RuntimeFactScanner().scan(source: source, path: path)
    }

    @Test("Objective-C 선언명은 명시적으로 알 수 있는 selector만 기록한다")
    func capturesReliableObjectiveCNames() {
        let facts = scan("""
            @objc(LegacyController)
            class Controller: NSObject {
                @objc(showItem:)
                func show(id: String) {}

                @objc func ping() {}
                @objc func consume(_ value: Int) {}
                @objc func ambiguous(value: Int) {}
            }

            @objc protocol Delegate {
                func finish()
            }
            """)

        let controller = facts.declarations.first { $0.name == "Controller" }
        #expect(controller?.objectiveCName == "LegacyController")
        #expect(controller?.location == CartographCore.SourceLocation(path: path, line: 2, column: 7))
        #expect(controller?.endLocation.line == 9)

        let show = facts.declarations.first { $0.name == "show" }
        #expect(show?.indexName == "show(id:)")
        #expect(show?.qualifiedName == "Controller.show")
        #expect(show?.objectiveCName == "showItem:")
        #expect(show?.parentLocation == controller?.location)
        #expect(show?.isTypeMember == true)
        #expect(show?.kind == .method)
        #expect(show?.location == CartographCore.SourceLocation(path: path, line: 4, column: 10))

        #expect(facts.declarations.first { $0.name == "ping" }?.objectiveCName == "ping")
        #expect(facts.declarations.first { $0.name == "consume" }?.objectiveCName == "consume:")
        // 외부 인자 이름은 Objective-C selector 조각과 반드시 같지 않으므로 추측하지 않는다.
        #expect(facts.declarations.first { $0.name == "ambiguous" }?.objectiveCName == nil)
        #expect(facts.declarations.first { $0.name == "finish" }?.objectiveCName == "finish")
    }

    @Test("리터럴과 불변 별칭의 결합은 풀고 가변 값은 미확정으로 남긴다")
    func resolvesImmutableNamesWithoutGuessingMutableValues() {
        let facts = scan("""
            let module = "App"
            let className = module + ".Controller"
            _ = NSClassFromString(className)
            _ = NSProtocolFromString("PluginProtocol")
            let selectorName = "reload" + ":"
            _ = NSSelectorFromString(selectorName)

            var mutable = "Ghost"
            mutable += "Controller"
            _ = NSClassFromString(mutable)
            """)

        let classLookups = facts.boundaries.filter { $0.kind == .classLookup }
        #expect(classLookups.count == 2)
        #expect(classLookups[0].api == "NSClassFromString")
        #expect(classLookups[0].name == "App.Controller")
        #expect(classLookups[0].nameOrigin == .constant)
        #expect(classLookups[0].calleeLocation == CartographCore.SourceLocation(path: path, line: 3, column: 5))
        #expect(classLookups[1].name == nil)
        #expect(classLookups[1].nameOrigin == .dynamic)

        let protocolLookup = facts.boundaries.first { $0.kind == .protocolLookup }
        #expect(protocolLookup?.name == "PluginProtocol")
        #expect(protocolLookup?.nameOrigin == .literal)

        let selectorLookup = facts.boundaries.first { $0.kind == .selectorLookup }
        #expect(selectorLookup?.name == "reload:")
        #expect(selectorLookup?.nameOrigin == .constant)
    }

    @Test("NSBundle 클래스 조회와 Objective-C selector 조회 함수도 후보로 기록한다")
    func capturesAdditionalSystemLookupSpellings() {
        let facts = scan("""
            _ = NSBundle.main.classNamed("App.Controller")
            _ = sel_getUid("reload:")
            """)

        #expect(facts.boundaries.first { $0.kind == .classLookup }?.api == "classNamed")
        #expect(facts.boundaries.first { $0.kind == .classLookup }?.name == "App.Controller")
        #expect(facts.boundaries.first { $0.kind == .selectorLookup }?.api == "sel_getUid")
        #expect(facts.boundaries.first { $0.kind == .selectorLookup }?.name == "reload:")
    }

    @Test("selector 참조와 별칭을 등록 API의 정확한 대상 위치까지 보존한다")
    func capturesSelectorReferencesAndRegistrations() {
        let facts = scan("""
            class Controller: NSObject {
                @objc func handle(_ sender: Any) {}
                @objc(reloadItem:) func reload(_ sender: Any) {}

                func wire(button: UIControl) {
                    let action = #selector(Controller.handle(_:))
                    let ready = Notification.Name("ready")
                    button.addTarget(self, action: action, for: .touchUpInside)
                    Timer.scheduledTimer(timeInterval: 1, target: self, selector: action, userInfo: nil, repeats: false)
                    NotificationCenter.default.addObserver(self, selector: action, name: ready, object: nil)
                    _ = UITapGestureRecognizer(target: self, action: action)
                    _ = Timer(timeInterval: 1, target: self, selector: action, userInfo: nil, repeats: false)
                    configure(target: self, action: action)
                    _ = #selector(Controller.reload(_:))
                    _ = #selector(Controller.ambiguous(value:))
                }

                @objc func ambiguous(value: Int) {}
            }
            """)

        let selector = facts.boundaries.first { $0.kind == .selectorReference }
        #expect(selector?.api == "#selector")
        #expect(selector?.name == "handle:")
        #expect(selector?.nameOrigin == .selector)
        #expect(selector?.receiverTypeName == "Controller")
        #expect(selector?.targetMemberName == "handle")
        #expect(selector?.referencedTargetLocation == CartographCore.SourceLocation(path: path, line: 6, column: 43))
        #expect(selector?.enclosingDeclarationLocation == CartographCore.SourceLocation(path: path, line: 5, column: 10))

        let registrations = facts.boundaries.filter { $0.kind == .selectorRegistration }
        #expect(registrations.map(\.api) == [
            "addTarget", "scheduledTimer", "UITapGestureRecognizer", "Timer",
        ])
        #expect(registrations.allSatisfy { $0.name == "handle:" && $0.nameOrigin == .selector })
        #expect(registrations.allSatisfy { $0.referencedTargetLocation == selector?.referencedTargetLocation })
        #expect(registrations.allSatisfy { $0.receiverTypeName == "Controller" })
        #expect(registrations.allSatisfy { $0.receiverOrigin == .explicitTarget })
        let notification = facts.boundaries.first { $0.kind == .notificationObserver }
        #expect(notification?.name == "handle:")
        #expect(notification?.notificationName == "ready")
        #expect(notification?.referencedTargetLocation == selector?.referencedTargetLocation)
        #expect(notification?.receiverTypeName == "Controller")
        #expect(notification?.receiverOrigin == .explicitTarget)
        #expect(notification?.notificationObjectIsNil == true)
        #expect(notification?.notificationCenterLocation?.line == 10)
        #expect(notification?.nameAPIReferences?.map(\.api) == ["Notification.Name"])
        #expect(facts.boundaries.first {
            $0.kind == .selectorReference && $0.targetMemberName == "reload"
        }?.name == "reloadItem:")
        let ambiguous = facts.boundaries.first {
            $0.kind == .selectorReference && $0.targetMemberName == "ambiguous"
        }
        #expect(ambiguous?.name == nil)
        #expect(ambiguous?.reason == "selector-name-requires-index-resolution")
    }

    @Test("perform 수신자의 self 타입과 타입 표식과 생성자 근거를 구분한다")
    func capturesSelectorInvocationReceiverHints() {
        let facts = scan("""
            class Controller: NSObject {
                @objc func refresh() {}

                func run() {
                    let action = #selector(refresh)
                    self.perform(action)
                    let typed: Controller = self
                    typed.perform(action)
                    let made = Controller()
                    made.perform(action)
                }
            }
            """)

        let invocations = facts.boundaries.filter { $0.kind == .selectorInvocation }
        #expect(invocations.map(\.receiverTypeName) == ["Controller", "Controller", "Controller"])
        #expect(invocations.map(\.receiverOrigin) == [.enclosingType, .annotation, .construction])
        #expect(invocations.allSatisfy { $0.name == "refresh" && $0.nameOrigin == .selector })
    }

    @Test("알림 이름 별칭의 등록과 게시를 같은 이름으로 연결한다")
    func capturesNotificationClosureAndPost() {
        let facts = scan("""
            let ready = Notification.Name("ready")
            let center = NotificationCenter.default
            center.addObserver(forName: ready, object: nil, queue: nil) { _ in }
            center.post(name: ready, object: nil)
            """)

        let observer = facts.boundaries.first { $0.kind == .notificationObserver }
        let post = facts.boundaries.first { $0.kind == .notificationPost }
        #expect(observer?.api == "addObserver")
        #expect(observer?.name == "ready")
        #expect(observer?.notificationName == "ready")
        #expect(observer?.nameOrigin == .constant)
        #expect(observer?.notificationObjectIsNil == true)
        #expect(observer?.notificationCenterLocation == CartographCore.SourceLocation(
            path: path, line: 2, column: 33
        ))
        #expect(observer?.notificationNameLocation?.line == 1)
        #expect(observer?.nameAPIReferences?.map(\.api) == ["Notification.Name"])
        #expect(post?.api == "post")
        #expect(post?.name == observer?.name)
        #expect(post?.notificationName == observer?.notificationName)
        #expect(post?.nameOrigin == .constant)
        #expect(post?.notificationCenterLocation == observer?.notificationCenterLocation)
        #expect(post?.notificationObjectIsNil == true)
    }

    @Test("클로저 observer는 기존 경계를 유지하고 publisher만 실행 주장 없는 구독 경계다")
    func capturesNotificationSubscriptionPoints() {
        let facts = scan("""
            let event = Notification.Name("ready")
            let center = NotificationCenter.default
            let session = NSObject()
            _ = center.addObserver(forName: event, object: session, queue: .main) { _ in }
            _ = center.publisher(for: event)
            _ = center.publisher(for: event).sink { _ in }
            onReceive(center.publisher(for: event)) { _ in }
            _ = center.publisher(for: event).customSink { _ in }
            """)

        let subscriptions = facts.boundaries.filter { $0.kind == .notificationSubscription }
        #expect(subscriptions.map(\.api) == ["publisher", "publisher", "publisher", "publisher"])
        #expect(subscriptions.map { $0.subscriptionConsumer?.api } == [nil, "sink", "onReceive", nil])
        #expect(subscriptions.allSatisfy { $0.notificationName == "ready" })
        #expect(subscriptions.allSatisfy { $0.notificationCenterLocation == CartographCore.SourceLocation(
            path: path, line: 2, column: 33
        ) })
        #expect(subscriptions.first?.notificationObjectIsNil == true)
        #expect(subscriptions.allSatisfy { $0.referencedTargetLocation == nil })
        let observer = facts.boundaries.first { $0.kind == .notificationObserver }
        #expect(observer?.api == "addObserver")
        #expect(observer?.notificationObjectIsNil == false)
    }

    @Test("Notification 객체 게시도 사라지지 않고 안전한 생성자만 이름을 푼다")
    func capturesNotificationPayloadPosts() {
        let facts = scan("""
            let ready = Notification.Name("ready")
            NotificationCenter.default.post(Notification(name: ready, object: nil))
            NotificationCenter.default.post(notification)
            """)

        let posts = facts.boundaries.filter { $0.kind == .notificationPost }
        #expect(posts.count == 2)
        #expect(posts.first?.notificationName == "ready")
        #expect(posts.first?.name == "ready")
        #expect(posts.first?.notificationObjectIsNil == true)
        #expect(posts.first?.nameAPIReferences?.map(\.api) == ["Notification.Name", "Notification"])
        #expect(posts.last?.notificationName == nil)
        #expect(posts.last?.name == nil)
        #expect(posts.last?.nameOrigin == .dynamic)
        #expect(posts.last?.reason == "runtime-notification-payload-not-statically-resolved")
    }

    @Test("추론형 알림 이름은 철자를 추측하지 않고 정확한 멤버 위치를 보존한다")
    func preservesImplicitNotificationNameReference() {
        let facts = scan("NotificationCenter.default.post(name: .ready, object: sender)")
        let post = facts.boundaries.first { $0.kind == .notificationPost }

        #expect(post?.name == nil)
        #expect(post?.notificationName == nil)
        #expect(post?.notificationNameLocation == CartographCore.SourceLocation(
            path: path, line: 1, column: 40
        ))
        #expect(post?.notificationObjectIsNil == false)
    }

    @Test("default가 아닌 알림 센터를 전역 기본 버스라고 추측하지 않는다")
    func leavesUnknownNotificationCenterUnidentified() {
        let facts = scan("customCenter.post(name: \"ready\", object: nil)")
        let post = facts.boundaries.first { $0.kind == .notificationPost }

        #expect(post?.notificationName == "ready")
        #expect(post?.notificationCenterLocation == nil)
    }

    @Test("같은 직선 스코프의 불변 center와 object는 생성 위치를 공유한다")
    func capturesLocalNotificationIdentitySites() {
        let facts = scan("""
            let center = NotificationCenter()
            let object = NSObject()
            _ = center.addObserver(forName: .ready, object: object, queue: nil) { _ in }
            center.post(name: .ready, object: object)
            """)
        let observer = facts.boundaries.first { $0.kind == .notificationObserver }
        let post = facts.boundaries.first { $0.kind == .notificationPost }

        #expect(observer?.notificationCenterLocation?.line == 1)
        #expect(post?.notificationCenterLocation == observer?.notificationCenterLocation)
        #expect(observer?.notificationCenterOwnerLocation == nil)
        #expect(observer?.notificationObjectLocation?.line == 2)
        #expect(post?.notificationObjectLocation == observer?.notificationObjectLocation)
    }

    @Test("직접 observer token 제거를 같은 scope의 이후 게시에만 보존한다")
    func capturesDirectNotificationRemovalProof() {
        let facts = scan("""
            func exercise() {
                let center = NotificationCenter()
                let object = NSObject()
                let token = center.addObserver(forName: .ready, object: object, queue: nil) { _ in }
                center.removeObserver(token)
                center.post(name: .ready, object: object)
            }
            """)
        let removal = facts.boundaries.first { $0.kind == .notificationPost }?
            .notificationRemovalReferences?.first

        #expect(removal?.registrationLocation.line == 4)
        #expect(removal?.removalLocation.line == 5)
        #expect(removal?.notificationCenterLocation.line == 2)
        #expect(removal?.notificationCenterOwnerLocation == nil)
    }

    @Test("mutable token과 분기 제거와 다른 center 제거는 확정 lifecycle 근거가 아니다")
    func rejectsUnprovenNotificationRemovalProof() {
        let facts = scan("""
            func exercise(_ flag: Bool) {
                let center = NotificationCenter()
                let other = NotificationCenter()
                let object = NSObject()
                let token = center.addObserver(forName: .ready, object: object, queue: nil) { _ in }
                var mutable = token
                if flag { center.removeObserver(token) }
                center.removeObserver(mutable)
                other.removeObserver(token)
                center.post(name: .ready, object: object)
            }
            """)
        let post = facts.boundaries.first { $0.kind == .notificationPost }

        #expect(post?.notificationRemovalReferences == nil)
    }

    @Test("불변 token alias와 같은 branch 제거만 그 경로의 post에 보존한다")
    func capturesAliasedBranchNotificationRemoval() {
        let facts = scan("""
            func exercise(_ flag: Bool) {
                let center = NotificationCenter.default
                let token = center.addObserver(forName: .ready, object: nil, queue: nil) { _ in }
                let alias = token
                if flag {
                    center.removeObserver(alias)
                    center.post(name: .ready, object: nil)
                }
                center.post(name: .ready, object: nil)
            }
            """)
        let posts = facts.boundaries.filter { $0.kind == .notificationPost }

        #expect(posts.first?.notificationRemovalReferences?.first?.registrationLocation.line == 3)
        #expect(posts.last?.notificationRemovalReferences == nil)
    }

    @Test("plain do의 defer는 scope 종료 뒤에만 observer 제거 근거가 된다")
    func modelsDeferredNotificationRemovalAtScopeExit() {
        let facts = scan("""
            func afterDo() {
                let center = NotificationCenter.default
                let token = center.addObserver(forName: .afterDo, object: nil, queue: nil) { _ in }
                do { defer { center.removeObserver(token) } }
                center.post(name: .afterDo, object: nil)
            }
            func beforeFunctionExit() {
                let center = NotificationCenter.default
                let token = center.addObserver(forName: .beforeExit, object: nil, queue: nil) { _ in }
                defer { center.removeObserver(token) }
                center.post(name: .beforeExit, object: nil)
            }
            """)
        let posts = facts.boundaries.filter { $0.kind == .notificationPost }

        #expect(posts.first?.notificationRemovalReferences?.count == 1)
        #expect(posts.last?.notificationRemovalReferences == nil)
    }

    @Test("직접 AnyCancellable alias 취소만 이후 post의 lifecycle 근거가 된다")
    func capturesDirectNotificationCancellation() {
        let facts = scan("""
            func cancelled(_ flag: Bool) {
                let center = NotificationCenter.default
                let token = center.publisher(for: .ready).sink { _ in }
                let alias = token
                alias.cancel()
                center.post(name: .ready, object: nil)
                var mutable = center.publisher(for: .mutable).sink { _ in }
                mutable.cancel()
                center.post(name: .mutable, object: nil)
                let branchToken = center.publisher(for: .branch).sink { _ in }
                if flag { branchToken.cancel() }
                center.post(name: .branch, object: nil)
            }
            """)
        let posts = facts.boundaries.filter { $0.kind == .notificationPost }

        #expect(posts.first?.notificationCancellationReferences?.first?.registrationLocation.line == 3)
        #expect(posts.first?.notificationCancellationReferences?.first?.cancellationLocation.line == 5)
        #expect(posts[1].notificationCancellationReferences?.allSatisfy {
            $0.registrationLocation.line != 7
        } == true)
        #expect(posts.last?.notificationCancellationReferences?.allSatisfy {
            $0.registrationLocation.line != 10
        } == true)
    }

    @Test("직접 for-await만 NotificationCenter AsyncSequence 소비 경계가 된다")
    func capturesAsyncNotificationSequenceConsumption() {
        let facts = scan("""
            func listen() async {
                for await _ in NotificationCenter.default.notifications(named: .ready) { break }
                _ = NotificationCenter.default.notifications(named: .bare)
                for await _ in custom.notifications(named: .custom) { break }
            }
            """)
        let subscriptions = facts.boundaries.filter { $0.kind == .notificationSubscription }

        #expect(subscriptions.map(\.api) == ["notifications", "notifications"])
        #expect(subscriptions.map { $0.subscriptionConsumer?.api } == ["for-await", "for-await"])
        #expect(subscriptions.map { $0.subscriptionConsumer?.location.line } == [2, 4])
        #expect(facts.limitations.contains("Notification stream registration calls not yet modeled: 1."))
    }

    @Test("분기 밖에서 만든 지역 인스턴스는 서로 다른 실행 경로의 동일성 근거가 아니다")
    func rejectsBranchSeparatedNotificationIdentitySites() {
        let facts = scan("""
            func wire(_ enabled: Bool) {
                let center = NotificationCenter()
                let object = NSObject()
                if enabled {
                    _ = center.addObserver(forName: .ready, object: object, queue: nil) { _ in }
                } else {
                    center.post(name: .ready, object: object)
                }
            }
            """)

        #expect(facts.boundaries.allSatisfy { $0.notificationCenterLocation == nil })
        #expect(facts.boundaries.allSatisfy { $0.notificationObjectLocation == nil })
    }

    @Test("NSWorkspace singleton center는 provider와 center property 위치를 따로 보존한다")
    func capturesWorkspaceNotificationCenterProofs() {
        let facts = scan("""
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { _ in }
            """)
        let observer = facts.boundaries.first { $0.kind == .notificationObserver }

        #expect(observer?.notificationCenterOwnerLocation?.line == 1)
        #expect(observer?.notificationCenterLocation?.line == 1)
        #expect(observer?.notificationCenterOwnerLocation != observer?.notificationCenterLocation)
        #expect(observer?.notificationName == nil)
        #expect(observer?.notificationNameLocation?.line == 2)
    }

    @Test("주석과 문자열 안의 API 철자는 런타임 경계가 아니다")
    func ignoresCommentsAndStringContents() {
        let facts = scan("""
            // NSClassFromString("Ghost")
            let text = "NSSelectorFromString(\\\"fake:\\\")"
            print(text)
            """)

        #expect(facts.boundaries.isEmpty)
        #expect(facts.limitations.isEmpty)
    }

    @Test("지원하지 않는 실제 런타임 패턴이 있을 때만 개수로 한계를 알린다")
    func reportsOnlyRelevantUnsupportedRuntimePatterns() {
        let facts = scan("""
            _ = center.publisher(for: .ready)
            _ = object.value(forKey: "title")
            configure(target: self, action: #selector(refresh))
            """)

        #expect(facts.limitations == [
            "Selector registration calls using APIs outside the supported runtime registry: 1.",
            "Key-value or predicate reflection calls not yet modeled: 1.",
        ])
    }

    @Test("분기 안의 동명 상수는 형제 분기나 바깥 사용 지점으로 새지 않는다")
    func keepsLexicalBindingsInsideTheirBranches() {
        let facts = scan("""
            let className = "Outer"
            func load(_ first: Bool) {
                if first {
                    let className = "First"
                    _ = NSClassFromString(className)
                } else {
                    let className = "Second"
                    _ = NSClassFromString(className)
                }
                _ = NSClassFromString(className)
            }
            """)

        let names = facts.boundaries.filter { $0.kind == .classLookup }.compactMap(\.name)
        #expect(names == ["First", "Second", "Outer"])
    }

    @Test("같은 스코프의 뒤 수신자 선언이 앞 사용의 타입을 바꾸지 않는다")
    func selectsReceiverBindingByUsePosition() {
        let facts = scan("""
            func run(action: Selector) {
                let object: First = First()
                object.perform(action)
                let object: Second = Second()
                object.perform(action)
            }
            """)

        let invocations = facts.boundaries.filter { $0.kind == .selectorInvocation }
        #expect(invocations.map(\.receiverTypeName) == ["First", "Second"])
        #expect(invocations.map { $0.receiverTypeLocation?.line } == [2, 4])
    }

    @Test("같은 스코프의 이름 값도 각 사용보다 앞선 가장 가까운 선언을 쓴다")
    func selectsNameBindingByUsePosition() {
        let facts = scan("""
            func load() {
                let className = "First"
                _ = NSClassFromString(className)
                let className = "Second"
                _ = NSClassFromString(className)
            }
            """)

        let lookups = facts.boundaries.filter { $0.kind == .classLookup }
        #expect(lookups.map(\.name) == ["First", "Second"])
    }

    @Test("조건부 컴파일 분기의 상수는 선택된 분기를 증명하기 전까지 확정하지 않는다")
    func keepsConditionalCompilationBindingsOpaque() {
        let facts = scan("""
            #if DEBUG
            let className = "DebugController"
            #else
            let className = "ReleaseController"
            #endif
            _ = NSClassFromString(className)
            """)

        let lookup = facts.boundaries.first { $0.kind == .classLookup }
        #expect(lookup?.name == nil)
        #expect(lookup?.nameOrigin == .dynamic)
    }

    @Test("함수와 클로저의 타입 표식 매개변수를 수신자 근거로 쓴다")
    func capturesTypedParameterReceiverHints() {
        let facts = scan("""
            func run(object: Controller, action: Selector) {
                object.perform(action)
            }
            let callback = { (object: OtherController) in
                object.perform("refresh")
            }
            """)

        let invocations = facts.boundaries.filter { $0.kind == .selectorInvocation }
        #expect(invocations.map(\.receiverTypeName) == ["Controller", "OtherController"])
        #expect(invocations.map(\.receiverOrigin) == [.annotation, .annotation])
        #expect(invocations.map { $0.receiverTypeLocation?.line } == [1, 4])
    }

    @Test("이름 생성자 위치는 별칭과 결합을 지나도 모두 보존한다")
    func preservesNameConstructorProofs() {
        let facts = scan("""
            let first = Selector("reload")
            let second = NSSelectorFromString(":")
            let combined = first + second
            object.perform(combined)
            let event = Name("ready")
            NotificationCenter.default.post(name: event, object: nil)
            """)

        let invocation = facts.boundaries.first { $0.kind == .selectorInvocation }
        #expect(invocation?.name == "reload:")
        #expect(invocation?.nameAPIReferences?.map(\.api) == [
            "Selector", "NSSelectorFromString", "String.+",
        ])
        let post = facts.boundaries.first { $0.kind == .notificationPost }
        #expect(post?.notificationName == "ready")
        #expect(post?.nameAPIReferences?.map(\.api) == ["Name"])
    }

    @Test("문자열 결합 연산자도 실제 String 연산인지 검증할 위치를 남긴다")
    func preservesStringConcatenationProof() {
        let facts = scan("""
            func +(lhs: String, rhs: String) -> String { "Other" }
            let name = "App." + "Controller"
            _ = NSClassFromString(name)
            """)

        let lookup = facts.boundaries.first { $0.kind == .classLookup }
        #expect(lookup?.name == "App.Controller")
        #expect(lookup?.nameAPIReferences?.map(\.api) == ["String.+"])
        #expect(lookup?.nameAPIReferences?.first?.location.line == 2)
    }

    @Test("문자열 보간은 알려진 원시값만 해석한다")
    func resolvesOnlyPrimitiveInterpolation() {
        let facts = scan("""
            let module = "App"
            let version = 2
            _ = NSClassFromString("\\(module).ControllerV\\(version)")
            _ = NSClassFromString("\\(String(describing: object))")
            """)

        let lookups = facts.boundaries.filter { $0.kind == .classLookup }
        #expect(lookups.map(\.name) == ["App.ControllerV2", nil])
    }

    @Test("4096바이트를 넘는 이름은 자르지 않고 동적으로 남긴다")
    func rejectsOversizedResolvedNames() {
        let value = String(repeating: "가", count: 1_366)
        let facts = scan("let name = \"\(value)\"\n_ = NSClassFromString(name)")
        let lookup = facts.boundaries.first { $0.kind == .classLookup }

        #expect(lookup?.name == nil)
        #expect(lookup?.nameOrigin == .dynamic)
        #expect(lookup?.reason == "runtime-name-exceeds-4096-bytes")
    }

    @Test("클래스와 static 선언 여부를 런타임 선언에 보존한다")
    func capturesStaticDeclarations() {
        let facts = scan("""
            class Factory: NSObject {
                @objc class func shared() {}
                @objc static func make() {}
                @objc func instance() {}
                static let token = "value"
                static var mutable = "value"
            }
            """)

        #expect(facts.declarations.first { $0.name == "shared" }?.isStatic == true)
        #expect(facts.declarations.first { $0.name == "make" }?.isStatic == true)
        #expect(facts.declarations.first { $0.name == "instance" }?.isStatic == false)
        #expect(facts.declarations.first { $0.name == "token" }?.isStatic == true)
        #expect(facts.declarations.first { $0.name == "token" }?.isImmutable == true)
        #expect(facts.declarations.first { $0.name == "mutable" }?.isImmutable == false)
    }

    @Test("KVC 쓰기 가능성은 let 불변성과 별도로 실제 setter 형태를 보존한다")
    func capturesSettableProperties() {
        let facts = scan("""
            final class Model: NSObject {
                @objc var stored = "value"
                @objc var readOnly: String { "value" }
                @objc var computed: String {
                    get { "value" }
                    set {}
                }
                @objc var observed = "value" {
                    didSet {}
                }
                @objc private(set) var restricted = "value"
            }
            """)

        #expect(facts.declarations.first { $0.name == "stored" }?.isSettable == true)
        #expect(facts.declarations.first { $0.name == "readOnly" }?.isSettable == false)
        #expect(facts.declarations.first { $0.name == "computed" }?.isSettable == true)
        #expect(facts.declarations.first { $0.name == "observed" }?.isSettable == true)
        #expect(facts.declarations.first { $0.name == "restricted" }?.isSettable == false)
    }

    @Test("property의 명시적 단순 타입만 마지막 타입 token 위치에 보존한다")
    func capturesExplicitPropertyValueTypes() {
        let facts = scan("""
            final class Model: NSObject {
                @objc var leaf: Module.Leaf? = nil
                @objc var inferred = Module.Leaf()
                @objc var generic: Box<Module.Leaf>
                @objc var erased: AnyObject
            }
            """)
        let leaf = facts.declarations.first { $0.name == "leaf" }

        #expect(leaf?.valueTypeName == "Module.Leaf")
        #expect(leaf?.valueTypeLocation?.line == 2)
        #expect(leaf?.valueTypeLocation?.column == 28)
        #expect(facts.declarations.first { $0.name == "inferred" }?.valueTypeName == nil)
        #expect(facts.declarations.first { $0.name == "generic" }?.valueTypeName == nil)
        #expect(facts.declarations.first { $0.name == "erased" }?.valueTypeName == nil)
    }

    @Test("직접 KVC 키와 확정 수신자를 read/write 경계로 구분한다")
    func capturesDirectKeyValueCoding() {
        let facts = scan("""
            final class Model: NSObject {
                @objc var title = "before"
            }
            func use(_ target: Model) {
                _ = target.value(forKey: "title")
                target.setValue("after", forKey: "title")
            }
            """)

        let accesses = facts.boundaries.filter { [.keyValueRead, .keyValueWrite].contains($0.kind) }
        #expect(accesses.map(\.kind) == [.keyValueRead, .keyValueWrite])
        #expect(accesses.map(\.name) == ["title", "title"])
        #expect(accesses.map(\.receiverTypeName) == ["Model", "Model"])
        #expect(accesses.map(\.api) == ["value", "setValue"])
        #expect(facts.declarations.first { $0.name == "Model" }?.isFinal == true)
        #expect(facts.declarations.first { $0.name == "title" }?.attributes.contains(.objc) == true)
        #expect(facts.declarations.first { $0.name == "title" }?.isSettable == true)
    }

    @Test("리터럴 KVC key path는 read와 write를 기존 단일 key와 구분한다")
    func capturesDirectKeyPathCoding() {
        let facts = scan("""
            final class Root: NSObject {
                @objc let leaf: Leaf
            }
            func use(_ root: Root) {
                _ = root.value(forKeyPath: "leaf.text")
                root.setValue("after", forKeyPath: "leaf.text")
            }
            """)
        let paths = facts.boundaries.filter { [.keyPathRead, .keyPathWrite].contains($0.kind) }

        #expect(paths.map(\.kind) == [.keyPathRead, .keyPathWrite])
        #expect(paths.map(\.name) == ["leaf.text", "leaf.text"])
        #expect(paths.map(\.keyPaths) == [["leaf.text"], ["leaf.text"]])
        #expect(paths.map(\.receiverTypeName) == ["Root", "Root"])
    }

    @Test("inline과 불변 local predicate의 완전한 제한 문법만 key path 경계가 된다")
    func capturesPredicateKeyPaths() {
        let facts = scan("""
            func inspect(_ root: Root, value: String) {
                _ = NSPredicate(format: "leaf.text == %@", value).evaluate(with: root)
                let predicate = NSPredicate(
                    format: "%K == %@ AND enabled == TRUE",
                    argumentArray: ["leaf.text", value]
                )
                _ = predicate.evaluate(with: root)
                var mutable = NSPredicate(format: "leaf.text == %@", value)
                _ = mutable.evaluate(with: root)
                _ = NSPredicate(format: "%K == %@", value, "not-a-key").evaluate(with: root)
            }
            """)
        let predicates = facts.boundaries.filter { $0.kind == .keyPathRead && $0.api == "evaluate" }

        #expect(predicates.map(\.keyPaths) == [["leaf.text"], ["enabled", "leaf.text"]])
        #expect(predicates.allSatisfy { $0.nameAPIReferences?.map(\.api) == ["NSPredicate.format"] })
        #expect(predicates.allSatisfy { $0.receiverTypeName == "Root" })
        #expect(facts.limitations.contains("Key-value or predicate reflection calls not yet modeled: 2."))
    }

    @Test("동적 키와 key path와 미상 수신자는 KVC property로 추측하지 않는다")
    func rejectsUnprovenKeyValueCodingSyntax() {
        let facts = scan("""
            func inspect(_ target: NSObject, key: String, unknown: Any) {
                _ = target.value(forKey: key)
                _ = target.value(forKey: "profile.name")
                _ = unknown.value(forKey: "title")
            }
            """)

        #expect(!facts.boundaries.contains { [.keyValueRead, .keyValueWrite].contains($0.kind) })
        #expect(facts.limitations.contains { $0.contains("Key-value or predicate reflection") })
    }

    @Test("지역 상수의 선언 전 사용을 뒤 값이나 바깥 값으로 확정하지 않는다")
    func doesNotResolveForwardLocalBindings() {
        let facts = scan("""
            let className = "Outer"
            func load() {
                _ = NSClassFromString(className)
                let className = "Inner"
                _ = NSClassFromString(className)
            }
            """)

        let lookups = facts.boundaries.filter { $0.kind == .classLookup }
        #expect(lookups.map(\.name) == [nil, "Inner"])
        #expect(lookups.map(\.nameOrigin) == [.dynamic, .constant])
    }

    @Test("SwiftSyntaxAnalyzer는 같은 파싱 결과에 런타임 사실을 함께 싣는다")
    func analyzerIncludesRuntimeFacts() {
        let facts = SwiftSyntaxAnalyzer().analyze(
            source: "_ = NSClassFromString(\"App.Controller\")",
            path: path
        )

        #expect(facts.runtimeFacts?.path == path)
        #expect(facts.runtimeFacts?.boundaries.first?.kind == .classLookup)
    }
}
