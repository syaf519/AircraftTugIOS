//
//  ViewController.swift
//  AircraftTug
//
//  Created by Anthony Dipilato on 11/7/17.
//  Copyright © 2017 Bumbol Inc. All rights reserved.
//

import UIKit
import BlueCapKit
import CoreBluetooth
import CDJoystick

class ViewController: UIViewController
{
    public enum AppError : Error {
        case dataCharactertisticNotFound
        case enabledCharactertisticNotFound
        case updateCharactertisticNotFound
        case serviceNotFound
        case invalidState
        case resetting
        case poweredOff
        case unknown
    }
    
    // UI Connections
    @IBOutlet weak var roundedCornerButton: UIButton!
    @IBOutlet weak var hornButton: UIButton!
    @IBOutlet weak var floodLightSwitch: UISwitch!
    @IBOutlet weak var hitchSwitch: UISwitch!
    @IBOutlet weak var strobeSwitch: UISwitch!
    @IBOutlet weak var joystick: CDJoystick!
    @IBOutlet weak var connectionStatusLabel: UILabel!
    @IBOutlet weak var valueLabel: UILabel!
    
    
    var dataCharacteristic : Characteristic?
    var peripheral: Peripheral?
    var timer: Timer!
    var joyY: CGFloat!
    var joyX: CGFloat!
    var joyR: CGFloat!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        roundedCornerButton.layer.cornerRadius = 4
        hornButton.layer.cornerRadius = 4
        // joystick handler
        joystick.trackingHandler = { joystickData in
            print(joystickData)
            self.joyY = joystickData.velocity.y
            self.joyX = joystickData.velocity.x
            self.joyR = joystickData.angle
            self.updateJoystick()
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activate()
    }
    
    // UI interactions
    // Horn Actions
    @IBAction func hornButtonDown(_ sender: Any) {
        hornOn()
        timer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(ViewController.hornOn), userInfo: nil, repeats: true)
    }
    @IBAction func hornButtonUp(_ sender: Any) {
        hornOff()
        timer.invalidate()
    }
    @objc private func hornOn(){
        write(command: "1,1")
    }
    func hornOff(){
        write(command: "2,1")
    }
    // Flood Light Actions
    @IBAction func floodLightsToggle(_ sender: Any) {
        if(floodLightSwitch.isOn){
            write(command: "1,2")
        }else{
            write(command: "2,2")
        }
    }
    // Strobe Actions
    @IBAction func strobeToggle(_ sender: Any) {
        if(strobeSwitch.isOn){
            write(command: "1,3")
        }else{
            write(command: "2,3")
        }
    }
    // Hitch Actions
    @IBAction func hitchToggle(_ sender: Any) {
        if(hitchSwitch.isOn){
            write(command: "1,4")
        }else{
            write(command: "2,4")
        }
    }
    // Joystick
    func updateJoystick(){
        var velocity = (joyX * joyX + joyY * joyY).squareRoot()
        if(velocity > 1) {velocity = 1}
        //print("x: \(joyX) y: \(joyY) velocity: \(velocity)")
    }
    
    
    func activate() {
        let serviceUUID = CBUUID(string:"FFE0")
        let dataCharacteristicUUID = CBUUID(string:"FFE1")
        
        
        // initialize central manager with restore key. The restore allows to reuse the same central manager in the future.
        let manager = CentralManager(options: [CBCentralManagerOptionRestoreIdentifierKey : "CentralManagerKey" as NSString])
        
        // A future stream that notifies us when the state of the central manager changes.
        let stateChangeFuture = manager.whenStateChanges()
        
        // handle state changes and return a scan future if the bluetooth is powered on.
        let scanFuture = stateChangeFuture.flatMap { state -> FutureStream<Peripheral> in
            switch state {
            case .poweredOn:
                DispatchQueue.main.async {
                    self.connectionStatusLabel.text = "start scanning"
                    print(self.connectionStatusLabel.text!)
                }
                // check if device is already connected
                
                // scan for peripherals that advertise the FFE0 service
                return manager.startScanning(forServiceUUIDs: [serviceUUID], capacity: 10)
            case .poweredOff:
                throw AppError.poweredOff
            case .unauthorized, .unsupported:
                throw AppError.invalidState
            case .resetting:
                throw AppError.resetting
            case .unknown:
                throw AppError.unknown
            }
        }
        
        scanFuture.onFailure { error in
            guard let appError = error as? AppError else {
                return
            }
            switch appError {
            case .invalidState:
                break
            case .resetting:
                manager.reset()
            case .poweredOff:
                break
            case .unknown:
                print("scanFuture: unknown error")
                break
            default:
                break
            }
        }
        
        // Connect to the first matching peripheral
        let connectionFuture = scanFuture.flatMap { p -> FutureStream<Void> in
            // stop scan as we find the first peripheral
            manager.stopScanning()
            self.peripheral = p
            guard let peripheral = self.peripheral else {
                throw AppError.unknown
            }
            DispatchQueue.main.async {
                self.connectionStatusLabel.text = "Found peripheral \(peripheral.identifier.uuidString). Trying to connect"
                print(self.connectionStatusLabel.text!)
            }
            // connect to the peripheral in order to trigger the connected mode
            return peripheral.connect(connectionTimeout: 10, capacity: 5)
        }
        
        // We will next discover the service UUID in order to be able to access its chacteristics
        let discoveryFuture = connectionFuture.flatMap { _ -> Future<Void> in
            guard let peripheral = self.peripheral else {
                throw AppError.unknown
            }
            return peripheral.discoverServices([serviceUUID])
            }.flatMap { _ -> Future<Void> in
                guard let discoveredPeripheral = self.peripheral else {
                    throw AppError.unknown
                }
                guard let service = discoveredPeripheral.services(withUUID:serviceUUID)?.first else{
                    throw AppError.serviceNotFound
                }
                self.peripheral = discoveredPeripheral
                DispatchQueue.main.async {
                    self.connectionStatusLabel.text = "Discovered service \(service.uuid.uuidString). Trying to discover characteristics"
                    print(self.connectionStatusLabel.text!)
                }
                // we have discovered the service, the next step is to discover the characteristic for read/write
                return service.discoverCharacteristics([dataCharacteristicUUID])
        }
        
        /**
         1 -- checks if the characteristic is correctly discovered
         2 -- Register for notifications using the dataFuture variable
         */
        let dataFuture = discoveryFuture.flatMap { _ -> Future<Void> in
            guard let discoveredPeripheral = self.peripheral else {
                throw AppError.unknown
            }
            guard let dataCharacteristic = discoveredPeripheral.services(withUUID:serviceUUID)?.first?.characteristics(withUUID:dataCharacteristicUUID)?.first else {
                throw AppError.dataCharactertisticNotFound
            }
            self.dataCharacteristic = dataCharacteristic
            DispatchQueue.main.async {
                self.connectionStatusLabel.text = "Discovered characteristic \(dataCharacteristic.uuid.uuidString)."
                print(self.connectionStatusLabel.text!)
            }
            // read the data from the characteristic
            self.read()
            // Ask the characteristic to start notifying for value change
            return dataCharacteristic.startNotifying()
            }.flatMap { _ -> FutureStream<Data?> in
                guard let discoveredPeripheral = self.peripheral else {
                    throw AppError.unknown
                }
                guard let characteristic = discoveredPeripheral.services(withUUID:serviceUUID)?.first?.characteristics(withUUID:dataCharacteristicUUID)?.first else {
                    throw AppError.dataCharactertisticNotFound
                }
                // register to receive a notification when  the value of the characteristic changes and return a future that handles those notifications
                return characteristic.receiveNotificationUpdates(capacity: 10)
        }
        
        // The onSuccees method is called every time the characteristic value changes
        dataFuture.onSuccess { data in
            let s = String(data:data!, encoding: .utf8)
            DispatchQueue.main.async {
                self.valueLabel.text = "notified value is \(String(describing: s))"
                print("===== New Value ====")
                print(s!)
            }
        }
        
        // handle any future in the previous chain
        dataFuture.onFailure { error in
            print("===== error ==== ")
            print(error)
            switch error {
            case PeripheralError.disconnected:
                self.peripheral?.reconnect()
            case AppError.serviceNotFound:
                break
            case AppError.dataCharactertisticNotFound:
                break
            default:
                break
            }
        }
        
    }

    func read(){
        // read a value from the characteristic
        let readFuture = self.dataCharacteristic?.read(timeout: 5)
        readFuture?.onSuccess { (_) in
            // the value is in the dataValue Property
            let s = String(data:(self.dataCharacteristic?.dataValue)!, encoding: .utf8)
            DispatchQueue.main.async {
                self.valueLabel.text = "Read value is \(String(describing: s))"
                print(self.valueLabel.text!)
            }
        }
        readFuture?.onFailure { (_) in
            self.valueLabel.text = "read error"
        }
    }
    
    func write(command: String){
        print("write()")
        let output = command + "\n";
        //write a value to the characteristic
        let writeFuture = self.dataCharacteristic?.write(data: output.data(using: .utf8)!, type: .withoutResponse)
        
        writeFuture?.onSuccess(completion: { (_) in
            print("write success")
        })
        writeFuture?.onFailure(completion: {(e) in
            print("========= write failed =====")
            print(e)
        })
    }


}

