//
//  Hook.swift
//  SNINetwork
//
//  Created by thinker on 2019/5/29.
//  Copyright © 2019 wanma-studio. All rights reserved.
//

import Foundation
import SNIURLProtocol

public class Hook {
  public init() { }
  
  public func test() {
    let configuration = URLSessionConfiguration.default
    var protocolClasses = [AnyClass]()
    protocolClasses.append(SNIURLProtocol.self)
    configuration.protocolClasses = protocolClasses

    let session = URLSession.init(configuration: configuration)

    var request = URLRequest(url: URL(string: "https://122.228.95.175/get")!)
    request.addValue("httpbin.thellsapi.com", forHTTPHeaderField: "Host")
    session.dataTask(with: request) { (data, urlResponse, error) in
      let json = try! JSONSerialization.jsonObject(with: data!, options: [])
      print("json:", json)
    }.resume()
  }
}
