//
// Created by Andres Canella on 7/27/18.
// Copyright (c) 2018 andres Canella. All rights reserved.
//

import Foundation
import RxSwift
import RealmSwift

public class UnsplashImageCache {
    var debugLogging:Bool
    var targetUnusedCount:Int
    //subscribe to status for status feedback
    public enum Status {
        case error(description:String)
        case requesting(path:String)
        case requestAPISuccess
        case requestImagesDone(succeeded:Int)
        case skipFetchTargetUnseenReached
    }
    public let status = PublishSubject<Status>()

    private let clientId:String
    private let collections:[String]?
    let serverPath = "https://api.unsplash.com/photos/random"

    public init(clientId:String, collections:[String]? = nil, debugLogging:Bool = true, maxUnusedCount:Int = 10) {
        self.clientId = clientId
        self.collections = collections
        self.debugLogging = debugLogging
        self.targetUnusedCount = maxUnusedCount
    }

    deinit { log(message: "deinit") }

    public func preCache(imageCount:Int = 3) {
        //skip if unseen count target reached
        let unseenCount = dbDownloadedUnseenCount()
        log(message: "unseen count: \(unseenCount)")
        if unseenCount >= self.targetUnusedCount {
            log(message: "Unseen count target reached, skip.")
            status.on(.next(.skipFetchTargetUnseenReached))
            return
        }

        //pending results
        var imageFetchSuccess = 0
        //build path
        var path = serverPath
        path += "?client_id=\(clientId)"
        path += "&count=\(imageCount)"
        if collections != nil {
            path += "&collections=\(collections!.joined(separator: ","))"
        }
        //request url
        guard let url = URL(string: path) else { status.on(.next(.error(description: "Could not assemble request URL, with path: \(path)"))); return }

        //request
        status.on(.next(.requesting(path: path)))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        _ = URLSession.shared.rx
                .response(request: request)
                .observeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                //format
                .flatMap { (response: URLResponse, data: Data) -> Observable<Data> in
                    if response is HTTPURLResponse {
                        self.status.on(.next(.requestAPISuccess))
                        return Observable.just(data)
                    } else {
                        return Observable.error(NSError(domain: "server response fail", code: -10, userInfo: nil))
                    }
                }
                .splitToElementData()
                .filter({ (image, publisher) -> Bool in
                    //already logged
                    if let element = self.dbElement(id: image.id) {
                        self.log(message: "has Element: \(element)")
                        //pass filter if not downloaded,
                        return !element.downloaded
                    } else {
                        self.log(message: "does not have ElementId: \(image.id)")
                        //register new element
                        let element = UnsplashImageCacheElement()
                        element.id = image.id
                        element.fullImageUrlPath = image.urlPath
                        element.title = image.title
                        element.publisherUsername = publisher.username
                        element.publisherNameFirst = publisher.nameFirst
                        element.publisherNameLast = publisher.nameLast
                        element.publisherCustomPortfolioUrlPath = publisher.urlPath
                        element.seen = Date.distantPast
                        self.saveDb(element: element)
                        return true
                    }
                })
                //download
                .flatMap { (image, publisher) -> Observable<(id:String, data:Data)> in
                    self.log(message: "Need to get asset: \(image.id)")
                    //image url
                    guard let url = URL(string: image.urlPath) else {
                        return Observable.error(NSError(domain: "Could not assemble image URL, with path: \(image.urlPath)", code: -10, userInfo: nil))
                    }
                    let request = URLRequest(url: url)
                    return URLSession.shared.rx
                            .response(request:request)
                            .map { (response: URLResponse, data: Data) -> (id:String, data:Data) in
                                return (id: image.id, data: data)
                            }
                }
                //save
                .map { (id:String, data:Data) -> Void in
                    do {
                        try self.save(data: data, id: id)
                        //log downloaded
                        let element = self.dbElement(id: id)
                        let realm = try! Realm()
                        try! realm.write {
                            element?.downloaded = true
                        }
                    } catch {
                        self.status.on(.next(.error(description: "Could not save image, error: \(error)")))
                    }
                }
                .subscribe(onNext: {
                    self.log(message: "onNext")
                    //count succeeded
                    imageFetchSuccess += 1
                }, onError: { error in
                    self.log(message: "onError: \(error)")
                    self.status.on(.next(.requestImagesDone(succeeded: imageFetchSuccess)))
                }, onCompleted: {
                    self.log(message: "onComplected")
                    //finished fetch job
                    self.status.on(.next(.requestImagesDone(succeeded: imageFetchSuccess)))
                })
    }

    public func randomElement() -> (image: UIImage, element:UnsplashImageCacheElement)? {
        let elements = dbDownloadedElements()
        if let unusedElement = elements.sorted(byKeyPath: "seen").first {
            //log used
            let realm = try! Realm()
            try! realm.write {
                unusedElement.seen = Date()
            }
            //get image
            if let data = try? get(id: unusedElement.id), let image = UIImage(data: data) {
                //return element with image
                return (image:image, element:unusedElement)
            }
        }
        return nil
    }

    public func debugListDbElements() {
        self.log(message: "----elements----")
        for element in dbElements() { self.log(message: "id: \(element.id), dl: \(element.downloaded), used: \(element.seen.description), url:\(element.fullImageUrlPath), username: \(element.publisherUsername ?? "nil"), nameFirst: \(element.publisherNameFirst ?? "nil"), nameLast: \(element.publisherNameLast ?? "nil"), title: \(element.title ?? "nil"), customPortfolio: \(element.publisherCustomPortfolioUrlPath ?? "nil")") }
        self.log(message: "----------------")
    }

    private func cacheUrl() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ImageCache", isDirectory: true)
    }

    private func save(data:Data, id:String) throws {
        //create directory if missing
        var isDir = ObjCBool(true)
        if !FileManager.default.fileExists(atPath: cacheUrl().path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: cacheUrl(), withIntermediateDirectories: false)
        }
        //save
        let filename = cacheUrl().appendingPathComponent(id)
        try data.write(to: filename)
    }

    private func get(id:String) throws -> Data {
        let filename = cacheUrl().appendingPathComponent(id)
        return try Data(contentsOf: filename)
    }

    private func saveDb(element:UnsplashImageCacheElement) {
        let realm = try! Realm()
        try! realm.write {
            realm.add(element, update: true)
        }
    }

    private func dbElements() -> Results<UnsplashImageCacheElement> {
        let realm = try! Realm()
        return realm.objects(UnsplashImageCacheElement.self)
    }

    private func dbDownloadedElements() -> Results<UnsplashImageCacheElement> {
        return dbElements().filter("downloaded == true")
    }

    private func dbDownloadedUnseenCount() -> Int {
        return dbDownloadedElements().filter("seen == %@", Date.distantPast).count
    }

    private func dbElement(id:String) ->  UnsplashImageCacheElement? {
        return dbElements().filter("id == '\(id)'").first
    }

    private func log(message:String) {
        if debugLogging {
            print("UIC: \(message)")
        }
    }

    private func cropToBounds(image: UIImage, size: CGSize) -> UIImage? {
        let rect = CGRect(x: (image.size.width - size.width) / 2, y: (image.size.height - size.height) / 2, width: size.width, height: size.height)
        if let imageRef = image.cgImage?.cropping(to: rect) {
            return UIImage(cgImage: imageRef, scale: image.scale, orientation: image.imageOrientation)
        }
        return nil
    }
}

public extension ObservableType where E == Data {
    public func splitToElementData() -> Observable<(image:(id:String, urlPath:String, title:String?), publisher:(username:String?, nameFirst:String?, nameLast:String?, urlPath:String?))> {
        return Observable.create { observer in
            return self.subscribe { event in
                switch event {
                case .next(let data):
                    guard  let json = try? JSONSerialization.jsonObject(with: data, options:[]) as! Array<[String:Any]> else {
                        observer.on(.error(NSError(domain: "Split to elements, failed", code: -11, userInfo: nil)))
                        return
                    }
                    //iterate
                    for element in json {
                        guard let id = element["id"] as? String else { observer.on(.error(NSError(domain: "Split to elements, missing 'id' key", code: -11, userInfo: nil))); return }
                        guard let fullImageUrlPath = (element["urls"] as! [String:Any])["full"] as? String else { observer.on(.error(NSError(domain: "Split to elements, missing 'urls':'full' key", code: -11, userInfo: nil))); return }
                        let title = (element["location"] as? [String:Any])?["title"] as? String
                        let username = (element["user"] as? [String:Any])?["username"] as? String
                        let nameFirst = (element["user"] as? [String:Any])?["first_name"] as? String
                        let nameLast = (element["user"] as? [String:Any])?["last_name"] as? String
                        let portfolioUlrPath = (element["user"] as? [String:Any])?["portfolio_url"] as? String

                        observer.on(.next((
                                image:(
                                        id:id,
                                        urlPath:fullImageUrlPath,
                                        title:title),
                                publisher:(
                                        username:username,
                                        nameFirst:nameFirst,
                                        nameLast:nameLast,
                                        urlPath:portfolioUlrPath
                                ))))
                    }
                case .error(let error):
                    observer.on(.error(error))
                case .completed:
                    observer.on(.completed)
                }
            }
        }
    }
}

public class UnsplashImageCacheElement:Object {
    @objc dynamic var id:String = ""
    @objc dynamic var fullImageUrlPath:String = ""
    @objc dynamic var title:String?
    @objc dynamic var publisherUsername:String?
    @objc dynamic var publisherNameFirst:String?
    @objc dynamic var publisherNameLast:String?
    @objc dynamic var publisherCustomPortfolioUrlPath:String?
    @objc dynamic var downloaded = false
    @objc dynamic var seen = Date.distantPast

    public override static func primaryKey() -> String? {
        return "id"
    }

    public func imageHumanUrl() -> URL? {
        return URL(string: "https://unsplash.com/photos/\(id)")
    }

    public func publisherHumanUrl() -> URL? {
        guard let hasPublisherId = publisherUsername else {
            return nil
        }
        return URL(string: "https://unsplash.com/@\(hasPublisherId)")
    }
}
