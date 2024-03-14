import Aztec
import Foundation
import WordPressKit
import WordPressFlux

protocol PostCoordinatorDelegate: AnyObject {
    func postCoordinator(_ postCoordinator: PostCoordinator, promptForPasswordForBlog blog: Blog)
}

class PostCoordinator: NSObject {

    enum SavingError: Error {
        case mediaFailure(AbstractPost)
        case unknown
    }

    @objc static let shared = PostCoordinator()

    private let coreDataStack: CoreDataStackSwift

    private var mainContext: NSManagedObjectContext {
        coreDataStack.mainContext
    }

    weak var delegate: PostCoordinatorDelegate?

    private let queue = DispatchQueue(label: "org.wordpress.postcoordinator")

    private var pendingDeletionPostIDs: Set<NSManagedObjectID> = []
    private var observerUUIDs: [AbstractPost: UUID] = [:]

    private let mediaCoordinator: MediaCoordinator

    private let mainService: PostService
    private let failedPostsFetcher: FailedPostsFetcher

    private let actionDispatcherFacade: ActionDispatcherFacade

    // MARK: - Initializers

    init(mainService: PostService? = nil,
         mediaCoordinator: MediaCoordinator? = nil,
         failedPostsFetcher: FailedPostsFetcher? = nil,
         actionDispatcherFacade: ActionDispatcherFacade = ActionDispatcherFacade(),
         coreDataStack: CoreDataStackSwift = ContextManager.sharedInstance()) {
        self.coreDataStack = coreDataStack

        let mainContext = self.coreDataStack.mainContext

        self.mainService = mainService ?? PostService(managedObjectContext: mainContext)
        self.mediaCoordinator = mediaCoordinator ?? MediaCoordinator.shared
        self.failedPostsFetcher = failedPostsFetcher ?? FailedPostsFetcher(mainContext)

        self.actionDispatcherFacade = actionDispatcherFacade
    }

    /// Upload or update a post in the server.
    ///
    /// - Parameter forceDraftIfCreating Please see `PostService.uploadPost:forceDraftIfCreating`.
    func save(_ postToSave: AbstractPost,
              automatedRetry: Bool = false,
              forceDraftIfCreating: Bool = false,
              defaultFailureNotice: Notice? = nil,
              completion: ((Result<AbstractPost, Error>) -> ())? = nil) {

        notifyNewPostCreated()

        prepareToSave(postToSave, automatedRetry: automatedRetry) { result in
            switch result {
            case .success(let post):
                self.upload(post: post, forceDraftIfCreating: forceDraftIfCreating, completion: completion)
            case .failure(let error):
                switch error {
                case SavingError.mediaFailure(let savedPost):
                    self.dispatchNotice(savedPost)
                default:
                    if let notice = defaultFailureNotice {
                        self.actionDispatcherFacade.dispatch(NoticeAction.post(notice))
                    }
                }

                completion?(.failure(error))
            }
        }
    }

    func autoSave(_ postToSave: AbstractPost, automatedRetry: Bool = false) {
        prepareToSave(postToSave, automatedRetry: automatedRetry) { result in
            switch result {
            case .success(let post):
                self.mainService.autoSave(post, success: { uploadedPost, _ in }, failure: { _ in })
            case .failure:
                break
            }
        }
    }

    /// - note: Deprecated (kahu-offline-mode) (See PostCoordinator.publish)
    func publish(_ post: AbstractPost) {
        if post.status == .draft {
            post.status = .publish
            post.isFirstTimePublish = true
        }

        if post.status != .scheduled {
            post.date_created_gmt = Date()
        }

        post.shouldAttemptAutoUpload = true

        save(post)
    }

    /// Publishes the post according to the current settings and user capabilities.
    ///
    /// - warning: Before publishing, ensure that the media for the post got
    /// uploaded. Managing media is not the responsibility of `PostRepository.`
    ///
    /// - warning: Work-in-progress (kahu-offline-mode)
    @MainActor
    func _publish(_ post: AbstractPost) async throws {
        let parameters = PostHelper.remotePost(with: post)
        if post.status == .draft {
            parameters.status = PostStatusPublish
            parameters.date = Date()
        } else {
            // Publish according to the currrent post settings: private, scheduled, etc.
        }
        do {
            let repository = PostRepository(coreDataStack: coreDataStack)
            let post = try await repository._upload(parameters, for: post)
            didPublish(post)
            show(PostCoordinator.makePublishSuccessNotice(for: post))
        } catch {
            show(PostCoordinator.makePublishFailureNotice(for: post, error: error))
            throw error
        }
    }

    @MainActor
    private func didPublish(_ post: AbstractPost) {
        if post.status == .publish {
            QuickStartTourGuide.shared.complete(tour: QuickStartPublishTour(), silentlyForBlog: post.blog)
        }
        if post.status == .scheduled {
            notifyNewPostScheduled()
        } else if post.status == .publish {
            notifyNewPostPublished()
        }
        SearchManager.shared.indexItem(post)
        AppRatingUtility.shared.incrementSignificantEvent()
    }

    private func show(_ notice: Notice) {
        actionDispatcherFacade.dispatch(NoticeAction.post(notice))
    }

    func moveToDraft(_ post: AbstractPost) {
        post.status = .draft
        save(post)
    }

    /// If media is still uploading it keeps track of the ongoing media operations and updates the post content when they finish.
    /// Then, it calls the completion block with the post ready to be saved/uploaded.
    ///
    /// - Parameter post: the post to save
    /// - Parameter automatedRetry: if this is an automated retry, without user intervenction
    /// - Parameter then: a block to perform after post is ready to be saved
    ///
    private func prepareToSave(_ post: AbstractPost, automatedRetry: Bool = false,
                               then completion: @escaping (Result<AbstractPost, SavingError>) -> ()) {
        post.autoUploadAttemptsCount = NSNumber(value: automatedRetry ? post.autoUploadAttemptsCount.intValue + 1 : 0)

        guard mediaCoordinator.uploadMedia(for: post, automatedRetry: automatedRetry) else {
            change(post: post, status: .failed) { savedPost in
                completion(.failure(SavingError.mediaFailure(savedPost)))
            }
            return
        }

        change(post: post, status: .pushing)

        if mediaCoordinator.isUploadingMedia(for: post) || post.hasFailedMedia {
            change(post: post, status: .pushingMedia)
            // Only observe if we're not already
            guard !isObserving(post: post) else {
                return
            }

            // Ensure that all synced media references are up to date
            let syncedMedia = post.media.filter { $0.remoteStatus == .sync }
            updateMediaBlocksBeforeSave(in: post, with: syncedMedia)

            let uuid = observeMedia(for: post, completion: completion)
            trackObserver(receipt: uuid, for: post)

            return
        } else {
            // Ensure that all media references are up to date
            updateMediaBlocksBeforeSave(in: post, with: post.media)
        }

        completion(.success(post))
    }

    func updateMediaBlocksBeforeSave(in post: AbstractPost, with media: Set<Media>) {
        guard let postContent = post.content else {
            return
        }
        let contentParser = GutenbergContentParser(for: postContent)
        media.forEach { self.updateReferences(to: $0, in: contentParser.blocks, post: post) }
        post.content = contentParser.html()
    }

    func cancelAnyPendingSaveOf(post: AbstractPost) {
        removeObserver(for: post)
    }

    func isUploading(post: AbstractPost) -> Bool {
        return post.remoteStatus == .pushing
    }

    func posts(for blog: Blog, containsTitle title: String, excludingPostIDs excludedPostIDs: [Int] = [], entityName: String? = nil, publishedOnly: Bool = false) -> NSFetchedResultsController<AbstractPost> {
        let context = self.mainContext
        let fetchRequest = NSFetchRequest<AbstractPost>(entityName: entityName ?? AbstractPost.entityName())

        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "date_created_gmt", ascending: false)]

        let blogPredicate = NSPredicate(format: "blog == %@", blog)
        let urlPredicate = NSPredicate(format: "permaLink != NULL")
        let noVersionPredicate = NSPredicate(format: "original == NULL")
        var compoundPredicates = [blogPredicate, urlPredicate, noVersionPredicate]
        if !title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            compoundPredicates.append(NSPredicate(format: "postTitle contains[c] %@", title))
        }
        if !excludedPostIDs.isEmpty {
            compoundPredicates.append(NSPredicate(format: "NOT (postID IN %@)", excludedPostIDs))
        }
        if publishedOnly {
            compoundPredicates.append(NSPredicate(format: "\(BasePost.statusKeyPath) == '\(PostStatusPublish)'"))
        }
        let resultPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: compoundPredicates)

        fetchRequest.predicate = resultPredicate

        let controller = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: context, sectionNameKeyPath: nil, cacheName: nil)
        do {
            try controller.performFetch()
        } catch {
            fatalError("Failed to fetch entities: \(error)")
        }
        return controller
    }

    func titleOfPost(withPermaLink value: String, in blog: Blog) -> String? {
        let context = self.mainContext
        let fetchRequest = NSFetchRequest<AbstractPost>(entityName: "AbstractPost")

        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "date_created_gmt", ascending: false)]

        let blogPredicate = NSPredicate(format: "blog == %@", blog)
        let urlPredicate = NSPredicate(format: "permaLink == %@", value)
        let noVersionPredicate = NSPredicate(format: "original == NULL")
        let compoundPredicates = [blogPredicate, urlPredicate, noVersionPredicate]

        let resultPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: compoundPredicates)

        fetchRequest.predicate = resultPredicate

        let result = try? context.fetch(fetchRequest)

        guard let post = result?.first else {
            return nil
        }

        return post.titleForDisplay()
    }

    /// This method checks the status of all post objects and updates them to the correct status if needed.
    /// The main cause of wrong status is the app being killed while uploads of posts are happening.
    ///
    @objc func refreshPostStatus() {
        Post.refreshStatus(with: coreDataStack)
    }

    /// - note: Deprecated (kahu-offline-mode)
    private func upload(post: AbstractPost, forceDraftIfCreating: Bool, completion: ((Result<AbstractPost, Error>) -> ())? = nil) {
        mainService.uploadPost(post, forceDraftIfCreating: forceDraftIfCreating, success: { [weak self] uploadedPost in
            guard let uploadedPost = uploadedPost else {
                completion?(.failure(SavingError.unknown))
                return
            }

            print("Post Coordinator -> upload succesfull: \(String(describing: uploadedPost.content))")

            if uploadedPost.isScheduled() {
                self?.notifyNewPostScheduled()
            } else if uploadedPost.isPublished() {
                self?.notifyNewPostPublished()
            }

            SearchManager.shared.indexItem(uploadedPost)

            let model = PostNoticeViewModel(post: uploadedPost)
            self?.actionDispatcherFacade.dispatch(NoticeAction.post(model.notice))

            completion?(.success(uploadedPost))
        }, failure: { [weak self] error in
            self?.dispatchNotice(post)

            completion?(.failure(error ?? SavingError.unknown))

            print("Post Coordinator -> upload error: \(String(describing: error))")
        })
    }

    func add(assets: [ExportableAsset], to post: AbstractPost) -> [Media?] {
        let media = assets.map { asset in
            return mediaCoordinator.addMedia(from: asset, to: post)
        }
        return media
    }

    private func observeMedia(for post: AbstractPost, completion: @escaping (Result<AbstractPost, SavingError>) -> ()) -> UUID {
        // Only observe if we're not already
        let handleSingleMediaFailure = { [weak self] in
            guard let `self` = self,
                self.isObserving(post: post) else {
                return
            }

            // One of the media attached to the post has already failed. We're changing the
            // status of the post to .failed so we don't need to observe for other failed media
            // anymore. If we do, we'll receive more notifications and we'll be calling
            // completion() multiple times.
            self.removeObserver(for: post)

            self.change(post: post, status: .failed) { savedPost in
                completion(.failure(SavingError.mediaFailure(savedPost)))
            }
        }

        return mediaCoordinator.addObserver({ [weak self](media, state) in
            guard let `self` = self else {
                return
            }
            switch state {
            case .ended:
                let successHandler = {
                    self.updateMediaBlocksBeforeSave(in: post, with: [media])

                    // Let's check if media uploading is still going, if all finished with success then we can upload the post
                    if !self.mediaCoordinator.isUploadingMedia(for: post) && !post.hasFailedMedia {
                        self.removeObserver(for: post)
                        completion(.success(post))
                    }
                }
                switch media.mediaType {
                case .video:
                    EditorMediaUtility.fetchRemoteVideoURL(for: media, in: post) { (result) in
                        switch result {
                        case .failure:
                            handleSingleMediaFailure()
                        case .success(let videoURL):
                            media.remoteURL = videoURL.absoluteString
                            successHandler()
                        }
                    }
                default:
                    successHandler()
                }
            case .failed:
                handleSingleMediaFailure()
            default:
                DDLogInfo("Post Coordinator -> Media state: \(state)")
            }
        }, forMediaFor: post)
    }

    private func updateReferences(to media: Media, in contentBlocks: [GutenbergParsedBlock], post: AbstractPost) {
        guard var postContent = post.content,
            let mediaID = media.mediaID?.intValue,
            let remoteURLStr = media.remoteURL else {
            return
        }
        var imageURL = remoteURLStr

        if let remoteLargeURL = media.remoteLargeURL {
            imageURL = remoteLargeURL
        } else if let remoteMediumURL = media.remoteMediumURL {
            imageURL = remoteMediumURL
        }

        let mediaLink = media.link
        let mediaUploadID = media.uploadID
        let gutenbergMediaUploadID = media.gutenbergUploadID
        if media.remoteStatus == .failed {
            return
        }

        var gutenbergBlockProcessors: [GutenbergProcessor] = []
        var gutenbergProcessors: [Processor] = []
        var aztecProcessors: [Processor] = []

        // File block can upload any kind of media.
        let gutenbergFileProcessor = GutenbergFileUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: remoteURLStr)
        gutenbergProcessors.append(gutenbergFileProcessor)

        if media.mediaType == .image {
            let gutenbergImgPostUploadProcessor = GutenbergImgUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: imageURL)
            gutenbergProcessors.append(gutenbergImgPostUploadProcessor)

            let gutenbergGalleryPostUploadProcessor = GutenbergGalleryUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: imageURL, mediaLink: mediaLink)
            gutenbergProcessors.append(gutenbergGalleryPostUploadProcessor)

            let imgPostUploadProcessor = ImgUploadProcessor(mediaUploadID: mediaUploadID, remoteURLString: remoteURLStr, width: media.width?.intValue, height: media.height?.intValue)
            aztecProcessors.append(imgPostUploadProcessor)

            let gutenbergCoverPostUploadProcessor = GutenbergCoverUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: remoteURLStr)
            gutenbergProcessors.append(gutenbergCoverPostUploadProcessor)

            let gutenbergMediaFilesUploadProcessor = GutenbergMediaFilesUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: remoteURLStr)
            gutenbergProcessors.append(gutenbergMediaFilesUploadProcessor)

        } else if media.mediaType == .video {
            let gutenbergVideoPostUploadProcessor = GutenbergVideoUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: remoteURLStr)
            gutenbergProcessors.append(gutenbergVideoPostUploadProcessor)

            let gutenbergCoverPostUploadProcessor = GutenbergCoverUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: remoteURLStr)
            gutenbergProcessors.append(gutenbergCoverPostUploadProcessor)

            let videoPostUploadProcessor = VideoUploadProcessor(mediaUploadID: mediaUploadID, remoteURLString: remoteURLStr, videoPressID: media.videopressGUID)
            aztecProcessors.append(videoPostUploadProcessor)

            let gutenbergMediaFilesUploadProcessor = GutenbergMediaFilesUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: remoteURLStr)
            gutenbergProcessors.append(gutenbergMediaFilesUploadProcessor)

            if let videoPressGUID = media.videopressGUID {
                let gutenbergVideoPressUploadProcessor = GutenbergVideoPressUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, videoPressGUID: videoPressGUID)
                gutenbergProcessors.append(gutenbergVideoPressUploadProcessor)
            }

        } else if media.mediaType == .audio {
            let gutenbergAudioProcessor = GutenbergAudioUploadProcessor(mediaUploadID: gutenbergMediaUploadID, serverMediaID: mediaID, remoteURLString: remoteURLStr)
            gutenbergProcessors.append(gutenbergAudioProcessor)
        } else if let remoteURL = URL(string: remoteURLStr) {
            let documentTitle = remoteURL.lastPathComponent
            let documentUploadProcessor = DocumentUploadProcessor(mediaUploadID: mediaUploadID, remoteURLString: remoteURLStr, title: documentTitle)
            aztecProcessors.append(documentUploadProcessor)
        }

        // Gutenberg processors need to run first because they are more specific/and target only content inside specific blocks
        gutenbergBlockProcessors.forEach { $0.process(contentBlocks) }
        postContent = gutenbergProcessors.reduce(postContent) { (content, processor) -> String in
            return processor.process(content)
        }

        // Aztec processors are next because they are more generic and only worried about HTML tags
        postContent = aztecProcessors.reduce(postContent) { (content, processor) -> String in
            return processor.process(content)
        }

        post.content = postContent
    }

    private func trackObserver(receipt: UUID, for post: AbstractPost) {
        queue.sync {
            observerUUIDs[post] = receipt
        }
    }

    private func removeObserver(for post: AbstractPost) {
        queue.sync {
            let uuid = observerUUIDs[post]

            observerUUIDs.removeValue(forKey: post)

            if let uuid = uuid {
                mediaCoordinator.removeObserver(withUUID: uuid)
            }
        }
    }

    private func isObserving(post: AbstractPost) -> Bool {
        var result = false
        queue.sync {
            result = observerUUIDs[post] != nil
        }
        return result
    }

    private func change(post: AbstractPost, status: AbstractPostRemoteStatus, then completion: ((AbstractPost) -> ())? = nil) {
        guard let context = post.managedObjectContext else {
            return
        }

        context.perform {
            if status == .failed {
                post.markAsFailedAndDraftIfNeeded()
            } else {
                post.remoteStatus = status
            }

            ContextManager.sharedInstance().saveContextAndWait(context)

            completion?(post)
        }
    }

    /// Cancel active and pending automatic uploads of the post.
    func cancelAutoUploadOf(_ post: AbstractPost) {
        cancelAnyPendingSaveOf(post: post)

        post.shouldAttemptAutoUpload = false

        let moc = post.managedObjectContext

        moc?.perform {
            try? moc?.save()
        }

        let notice = Notice(title: PostAutoUploadMessages(for: post).cancelMessage(), message: "")
        actionDispatcherFacade.dispatch(NoticeAction.post(notice))
    }

    private func dispatchNotice(_ post: AbstractPost) {
        DispatchQueue.main.async {
            let model = PostNoticeViewModel(post: post)
            self.actionDispatcherFacade.dispatch(NoticeAction.post(model.notice))
        }
    }

    // MARK: - Trash/Delete

    func isDeleting(_ post: AbstractPost) -> Bool {
        pendingDeletionPostIDs.contains(post.objectID)
    }

    /// Moves the post to trash or delets it permanently in case it's already in trash.
    @MainActor
    func delete(_ post: AbstractPost) async {
        assert(post.managedObjectContext == mainContext)

        WPAnalytics.track(.postListTrashAction, withProperties: propertiesForAnalytics(for: post))

        setPendingDeletion(true, post: post)

        let trashed = (post.status == .trash)

        let repository = PostRepository(coreDataStack: ContextManager.shared)
        do {
            try await repository.trash(TaggedManagedObjectID(post))

            if trashed {
                cancelAnyPendingSaveOf(post: post)
                MediaCoordinator.shared.cancelUploadOfAllMedia(for: post)
            }

            // Remove the trashed post from spotlight
            SearchManager.shared.deleteSearchableItem(post)

            let message: String
            switch post {
            case _ as Post:
                message = trashed ? Strings.deletePost : Strings.movePostToTrash
            case _ as Page:
                message = trashed ? Strings.deletePage : Strings.movePageToTrash
            default:
                fatalError("Unsupported item: \(type(of: post))")
            }

            let notice = Notice(title: message)
            ActionDispatcher.dispatch(NoticeAction.dismiss)
            ActionDispatcher.dispatch(NoticeAction.post(notice))

            // No need to notify as the object gets deleted
            setPendingDeletion(false, post: post, notify: false)
        } catch {
            if let error = error as NSError?, error.code == Constants.httpCodeForbidden {
                delegate?.postCoordinator(self, promptForPasswordForBlog: post.blog)
            } else {
                WPError.showXMLRPCErrorAlert(error)
            }

            setPendingDeletion(false, post: post)
        }
    }

    private func setPendingDeletion(_ isDeleting: Bool, post: AbstractPost, notify: Bool = true) {
        if isDeleting {
            pendingDeletionPostIDs.insert(post.objectID)
        } else {
            pendingDeletionPostIDs.remove(post.objectID)
        }
        if notify {
            NotificationCenter.default.post(name: .postCoordinatorDidUpdate, object: self, userInfo: [
                NSUpdatedObjectsKey: Set([post])
            ])
        }
    }

    private func propertiesForAnalytics(for post: AbstractPost) -> [String: AnyObject] {
        var properties = [String: AnyObject]()
        properties["type"] = ((post is Post) ? "post" : "page") as AnyObject
        if let dotComID = post.blog.dotComID {
            properties[WPAppAnalyticsKeyBlogID] = dotComID
        }
        return properties
    }
}

private struct Constants {
    static let httpCodeForbidden = 403
}

extension Foundation.Notification.Name {
    /// Contains a set of updated objects under the `NSUpdatedObjectsKey` key
    static let postCoordinatorDidUpdate = Foundation.Notification.Name("org.automattic.postCoordinatorDidUpdate")
}

// MARK: - Automatic Uploads

extension PostCoordinator: Uploader {
    func resume() {
        failedPostsFetcher.postsAndRetryActions { [weak self] postsAndActions in
            guard let self = self else {
                return
            }

            postsAndActions.forEach { post, action in
                self.trackAutoUpload(action: action, status: post.status)

                switch action {
                case .upload:
                    self.save(post, automatedRetry: true)
                case .autoSave:
                    self.autoSave(post, automatedRetry: true)
                case .uploadAsDraft:
                    self.save(post, automatedRetry: true, forceDraftIfCreating: true)
                case .nothing:
                    return
                }
            }
        }
    }

    private func trackAutoUpload(action: PostAutoUploadInteractor.AutoUploadAction, status: BasePost.Status?) {
        guard action != .nothing, let status = status else {
            return
        }
        WPAnalytics.track(.autoUploadPostInvoked, withProperties:
            ["upload_action": action.rawValue,
             "post_status": status.rawValue])
    }
}

extension PostCoordinator {
    /// Fetches failed posts that should be retried when there is an internet connection.
    class FailedPostsFetcher {
        private let managedObjectContext: NSManagedObjectContext

        init(_ managedObjectContext: NSManagedObjectContext) {
            self.managedObjectContext = managedObjectContext
        }

        func postsAndRetryActions(result: @escaping ([AbstractPost: PostAutoUploadInteractor.AutoUploadAction]) -> Void) {
            let interactor = PostAutoUploadInteractor()
            managedObjectContext.perform {
                let request = NSFetchRequest<AbstractPost>(entityName: NSStringFromClass(AbstractPost.self))
                request.predicate = NSPredicate(format: "remoteStatusNumber == %d", AbstractPostRemoteStatus.failed.rawValue)
                let posts = (try? self.managedObjectContext.fetch(request)) ?? []

                let postsAndActions = posts.reduce(into: [AbstractPost: PostAutoUploadInteractor.AutoUploadAction]()) { result, post in
                    result[post] = interactor.autoUploadAction(for: post)
                }
                result(postsAndActions)
            }
        }
    }
}

private enum Strings {
    static let movePostToTrash = NSLocalizedString("postsList.movePostToTrash.message", value: "Post moved to trash", comment: "A short message explaining that a post was moved to the trash bin.")
    static let deletePost = NSLocalizedString("postsList.deletePost.message", value: "Post deleted permanently", comment: "A short message explaining that a post was deleted permanently.")
    static let movePageToTrash = NSLocalizedString("postsList.movePageToTrash.message", value: "Page moved to trash", comment: "A short message explaining that a page was moved to the trash bin.")
    static let deletePage = NSLocalizedString("postsList.deletePage.message", value: "Page deleted permanently", comment: "A short message explaining that a page was deleted permanently.")
}
