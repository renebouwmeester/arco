// Works the switch of a debug build of Arco from the command line: swift Design/debug-switch.swift on|off
import Foundation
let state = CommandLine.arguments.dropFirst().first ?? "on"
DistributedNotificationCenter.default().postNotificationName(.init("nl.renebouwmeester.arco.debug"), object: state,
                                                              userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
