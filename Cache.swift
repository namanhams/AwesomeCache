//
//  Cache.swift
//  Example
//
//  Created by Alexander Schuch on 12/07/14.
//  Copyright (c) 2014 Alexander Schuch. All rights reserved.
//

import Foundation

/**
 *  Represents the expiry of a cached object
 */
public enum CacheExpiry {
	case never
	case seconds(TimeInterval)
	case date(Foundation.Date)
}

/**
 *  A generic cache that persists objects to disk and is backed by a NSCache.
 *  Supports an expiry date for every cached object. Expired objects are automatically deleted upon their next access via `objectForKey:`. 
 *  If you want to delete expired objects, call `removeAllExpiredObjects`.
 *
 *  Subclassing notes: This class fully supports subclassing. 
 *  The easiest way to implement a subclass is to override `objectForKey` and `setObject:forKey:expires:`, e.g. to modify values prior to reading/writing to the cache.
 */
open class Cache<T: NSCoding> {
	open let name: String
	open let cacheDirectory: String
	
    fileprivate let cache:NSCache<AnyObject, AnyObject>?
	fileprivate let fileManager = FileManager()
	fileprivate let diskWriteQueue: DispatchQueue = DispatchQueue(label: "com.aschuch.cache.diskWriteQueue", attributes: [])
	fileprivate let diskReadQueue: DispatchQueue = DispatchQueue(label: "com.aschuch.cache.diskReadQueue", attributes: [])
	
	
	// MARK: Initializers
	
	/**
	 *  Designated initializer.
	 * 
	 *  @param name			Name of this cache
	 *	@param directory	Objects in this cache are persisted to this directory. 
	 *						If no directory is specified, a new directory is created in the system's Caches directory
	 *
	 *  @return				A new cache with the given name and directory
	 *
	 */
    public init(name: String, directory: String?, enableMemoryCache:Bool = true) {
		self.name = name
        
        if enableMemoryCache {
            cache = NSCache()
            cache?.name = name
        }
        else {
            cache = nil
        }
		
		if let d = directory {
			cacheDirectory = d
		} else {
			let dir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
			cacheDirectory = dir!.appendingFormat("/com.aschuch.cache/%@", name)
		}
		
		// Create directory on disk
		if !fileManager.fileExists(atPath: cacheDirectory) {
			do {
				try fileManager.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
			} catch _ {
			}
		}
	}
	
	/**
	 *  @param name		Name of this cache
	 *
	 *  @return			A new cache with the given name and the default cache directory
	 */
	public convenience init(name: String) {
		self.init(name: name, directory: nil)
	}
	
		
	// MARK: Get object
	
	/**
	 *  Looks up and returns an object with the specified name if it exists.
	 *  If an object is already expired, it is automatically deleted and `nil` will be returned.
	 *  
	 *  @param name		The name of the object that should be returned
	 *  @return			The cached object for the given name, or nil
	 */
    open func objectForKey(_ key: String, removeIfExpired:Bool=true) -> T? {
		var possibleObject: CacheObject?
				
		// Check if object exists in local cache
		possibleObject = cache?.object(forKey: key as AnyObject) as? CacheObject
		
		if possibleObject == nil {
			// Try to load object from disk (synchronously)
			diskReadQueue.sync {
				let path = self.pathForKey(key)
				if self.fileManager.fileExists(atPath: path) {
                    if let data = NSData(contentsOfFile: path) {
                        do {
                            possibleObject = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? CacheObject
                        }
                        catch {}
                    }
				}
			}
		}
		
		// Check if object is not already expired and return
		// Delete object if expired
		if let object = possibleObject {
			if !object.isExpired() {
				return object.value as? T
			} else {
                if removeIfExpired {
                    removeObjectForKey(key)
                }
			}
		}
		
		return nil
	}
	
	
	// MARK: Set object
	
	/**
	 *  Adds a given object to the cache.
	 *
	 *  @param object	The object that should be cached
	 *  @param forKey	A key that represents this object in the cache
	 */
	open func setObjectSynchronously(_ object: T, forKey key: String, expires: CacheExpiry = .never) {
        let expiryDate = expiryDateForCacheExpiry(expires)
        let cacheObject = CacheObject(value: object, expiryDate: expiryDate)
        
        // Set object in local cache
        cache?.setObject(cacheObject, forKey: key as AnyObject)
        
        // Write object to disk (asyncronously)
        diskWriteQueue.sync {
            let path = self.pathForKey(key)
            NSKeyedArchiver.archiveRootObject(cacheObject, toFile: path)
        }
	}
	
	/**
	 *  Adds a given object to the cache.
	 *  The object is automatically marked as expired as soon as its expiry date is reached.
	 *
	 *  @param object	The object that should be cached
	 *  @param forKey	A key that represents this object in the cache
	 */
	open func setObject(_ object: T, forKey key: String, expires: CacheExpiry = .never, completion: (() -> Void)? = nil) {
        DispatchQueue.global().async {
            self.setObjectSynchronously(object, forKey: key, expires: expires)
            DispatchQueue.main.async {
                completion?()
            }
        }
	}
	
	
	// MARK: Remove objects
    open func removeObjectForKeySynchronously(_ key: String) {
        cache?.removeObject(forKey: key as AnyObject)
        
        diskWriteQueue.sync {
            let path = self.pathForKey(key)
            do {
                try self.fileManager.removeItem(atPath: path)
            } catch _ {
            }
        }
    }
    
    
	/** 
	 *  Removes an object from the cache.
	 *  
	 *  @param key	The key of the object that should be removed
	 */
	open func removeObjectForKey(_ key: String, completion: (() -> Void)? = nil) {
        DispatchQueue.global().async {
            self.removeObjectForKeySynchronously(key)
            DispatchQueue.main.async {
                completion?()
            }
        }
	}
	
    open func removeAllObjectsSynchronously() {
        cache?.removeAllObjects()
        
        diskWriteQueue.sync {
            let paths = (try! self.fileManager.contentsOfDirectory(atPath: self.cacheDirectory))
            let keys = self.map(paths, { (obj) -> String in
                return String(NSString(string:obj).deletingPathExtension)
            })
            
            for key in keys {
                let path = self.pathForKey(key)
                do {
                    try self.fileManager.removeItem(atPath: path)
                } catch _ {
                }
            }
        }
    }
    
	/**
	 *  Removes all objects from the cache.
	 *
	 *  @param completion	Called as soon as all cached objects are removed from disk.
	 */
	open func removeAllObjects(_ completion: (() -> Void)? = nil) {
        DispatchQueue.global().async {
            self.removeAllObjectsSynchronously()
            DispatchQueue.main.async {
                completion?()
            }
        }
	}
	
	
	// MARK: Remove Expired Objects
	
    open func removeExpiredObjectsSynchronously() {
        diskWriteQueue.sync {
            let paths = (try! self.fileManager.contentsOfDirectory(atPath: self.cacheDirectory))
            let keys = self.map(paths, { (obj) -> String in
                return String(NSString(string:obj).deletingPathExtension)
            })
            
            for key in keys {
                // deletes the object if it is expired
                _ = self.objectForKey(key, removeIfExpired: true)
            }
        }
    }
    
	/**
	 *  Removes all expired objects from the cache.
	 */
	open func removeExpiredObjects(_ completion: (() -> Void)? = nil) {
        DispatchQueue.global().async {
            self.removeExpiredObjectsSynchronously()
            DispatchQueue.main.async {
                completion?()
            }
        }
	}
	
	
	// MARK: Subscripting
	
	open subscript(key: String) -> T? {
		get {
			return objectForKey(key)
		}
		set(newValue) {
			if let value = newValue {
				setObject(value, forKey: key)
			} else {
				removeObjectForKey(key)
			}
		}
	}
	
	
	// MARK: Private Helper
	
	fileprivate func pathForKey(_ key: String) -> String {
		let k = sanitizedKey(key)
		return NSString(string: NSString(string:cacheDirectory).appendingPathComponent(k)).appendingPathExtension("cache")!
	}
	
	fileprivate func sanitizedKey(_ key: String) -> String {
		let regex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_]+", options: NSRegularExpression.Options())
		let range = NSRange(location: 0, length: key.characters.count)
		return regex.stringByReplacingMatches(in: key, options: NSRegularExpression.MatchingOptions(), range: range, withTemplate: "-")
	}

	fileprivate func expiryDateForCacheExpiry(_ expiry: CacheExpiry) -> Date {
		switch expiry {
		case .never:
			return Date.distantFuture 
		case .seconds(let seconds):
			return Date().addingTimeInterval(seconds)
		case .date(let date):
			return date
		}
	}
    
    fileprivate func map(_ source:[String], _ block:((String) -> String)) -> [String] {
        var res = [String]()
        for object in source {
            res.append(block(object))
        }
        
        return res
    }

}

