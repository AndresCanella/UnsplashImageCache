# UnsplashImageCache

Will batch download images and save into a chache every time that preCache is called. randomElement() will provide a one of the random cached images and will rotate which is shown to always shot the image that has not been shown since the longest.

This currently has limited functionallity, what it does it does well. If you're interested in extending this functionality, I'll happily integrate any good new feature you come up with.

## Ussage

Initialize object with your Unsplash info and target collections string array.

```
let u = UnsplashImageCache(clientId:<your Unsplash client id>, collections:<colection ids>, debugLogging:true, maxUnusedCount:10)
```

Precache images:

```
u.preCache(imageCount:3)
```

Get image item:

```
let e = u.randomElement()
e.image
```

Optionally, subscribe to get system updates:

```
u.status.subscribe(onNext: { status in
    switch status {
    case .requesting(let path):
        print("requesting: \(path)")
    case .error(let description):
        print("error: \(description)")
    case .requestAPISuccess:
        print("requestSuccess")
    case .requestImagesDone(let succeeded):
        print("requestImagesDone: \(succeeded)")
    case .skipFetchTargetUnseenReached:
        print("skipFetchTargetUnseenReached")
    }
})
```

Or request list of cached items:

```
u.debugListDbElements()
```
## Features
* Rx Based
* Lazy load images bit by bit
* download and cache images
* background threaded
* Always shows first seen image (oldest)
## Requirements
Just install these pods
* RxSwift
* RealmSwift
