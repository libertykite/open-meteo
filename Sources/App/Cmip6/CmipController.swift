import Foundation
import SwiftPFor2D
import Vapor


struct CmipController {
    func query(_ req: Request) throws -> EventLoopFuture<Response> {
        try req.ensureSubdomain("climate-api")
        let generationTimeStart = Date()
        let params = try req.query.decode(CmipQuery.self)
        try params.validate()
        let elevationOrDem = try params.elevation ?? Dem90.read(lat: params.latitude, lon: params.longitude)
        
        let allowedRange = Timestamp(1950, 1, 1) ..< Timestamp(2051, 1, 1)
        //let timezone = try params.resolveTimezone()
        let time = try params.getTimerange(allowedRange: allowedRange)
        //let hourlyTime = time.range.range(dtSeconds: 3600)
        let dailyTime = time.range.range(dtSeconds: 3600*24)
        let biasCorrection = !(params.disable_bias_correction ?? false)
        
        let domains = try Cmip6Domain.load(commaSeparatedOptional: params.models) ?? [.MRI_AGCM3_2_S]
        
        let readers: [any Cmip6Readerable] = try domains.map { domain -> any Cmip6Readerable in
            if biasCorrection {
                guard let reader = try Cmip6BiasCorrectorEra5Seamless(domain: domain, lat: params.latitude, lon: params.longitude, elevation: elevationOrDem, mode: params.cell_selection ?? .land) else {
                    throw ForecastapiError.noDataAvilableForThisLocation
                }
                return Cmip6ReaderPostBiasCorrected(reader: reader, domain: domain)
            } else {
                guard let reader = try GenericReader<Cmip6Domain, Cmip6Variable>(domain: domain, lat: params.latitude, lon: params.longitude, elevation: elevationOrDem, mode: params.cell_selection ?? .land) else {
                    throw ForecastapiError.noDataAvilableForThisLocation
                }
                let reader2 = Cmip6ReaderPreBiasCorrection(reader: reader, domain: domain)
                return Cmip6ReaderPostBiasCorrected(reader: reader2, domain: domain)
            }
        }
        
        guard !readers.isEmpty else {
            throw ForecastapiError.noDataAvilableForThisLocation
        }

        // Start data prefetch to boooooooost API speed :D
        /*if let hourlyVariables = params.hourly {
            for reader in readers {
                try reader.prefetchData(variables: hourlyVariables, time: hourlyTime)
            }
        }*/
        let paramsDaily = try Cmip6VariableOrDerivedPostBias.load(commaSeparatedOptional: params.daily)
        if let dailyVariables = paramsDaily {
            for reader in readers {
                try reader.prefetchData(variables: dailyVariables, time: dailyTime)
            }
        }
        
        
        /*let hourly: ApiSection? = try params.hourly.map { variables in
            var res = [ApiColumn]()
            res.reserveCapacity(variables.count * readers.count)
            for reader in readers {
                for variable in variables {
                    let name = readers.count > 1 ? "\(variable.rawValue)_\(reader.reader.reader.domain.rawValue)" : variable.rawValue
                    let d = try reader.get(variable: variable, time: hourlyTime).convertAndRound(params: params).toApi(name: name)
                    assert(hourlyTime.count == d.data.count)
                    res.append(d)
                }
            }
            return ApiSection(name: "hourly", time: hourlyTime, columns: res)
        }*/
        let daily: ApiSection? = try paramsDaily.map { dailyVariables in
            var res = [ApiColumn]()
            res.reserveCapacity(dailyVariables.count * readers.count)
            for (reader, domain) in zip(readers, domains) {
                for variable in dailyVariables {
                    let name = readers.count > 1 ? "\(variable.rawValue)_\(domain.rawValue)" : variable.rawValue
                    let d = try reader.get(variable: variable, time: dailyTime).convertAndRound(params: params).toApi(name: name)
                    assert(dailyTime.count == d.data.count)
                    res.append(d)
                }
            }
            
            return ApiSection(name: "daily", time: dailyTime, columns: res)
        }
        
        let generationTimeMs = Date().timeIntervalSince(generationTimeStart) * 1000
        let out = ForecastapiResult(
            latitude: readers[0].modelLat,
            longitude: readers[0].modelLon,
            elevation: readers[0].targetElevation,
            generationtime_ms: generationTimeMs,
            utc_offset_seconds: 0,
            timezone: TimeZone(identifier: "GMT")!,
            current_weather: nil,
            sections: [/*hourly,*/ daily].compactMap({$0}),
            timeformat: params.timeformatOrDefault
        )
        return req.eventLoop.makeSucceededFuture(try out.response(format: params.format ?? .json))
    }
}

protocol Cmip6Readerable {
    func prefetchData(variables: [Cmip6VariableOrDerivedPostBias], time: TimerangeDt) throws
    func get(variable: Cmip6VariableOrDerivedPostBias, time: TimerangeDt) throws -> DataAndUnit
    var modelLat: Float { get }
    var modelLon: Float { get }
    var modelElevation: ElevationOrSea { get }
    var targetElevation: Float { get }
    var modelDtSeconds: Int { get }
}

/// Derived variables that do not need bias correction, but use bias corrected inputs
enum Cmip6VariableDerivedPostBiasCorrection: String, GenericVariableMixable, CaseIterable {
    case snowfall_sum
    case rain_sum
    case dewpoint_2m_max
    case dewpoint_2m_min
    case dewpoint_2m_mean
    case growing_degree_days_base_0_limit_50
    
    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

enum Cmip6VariableDerivedBiasCorrected: String, GenericVariableMixable, CaseIterable, GenericVariableBiasCorrectable {

    case et0_fao_evapotranspiration_sum
    case leaf_wetness_probability_mean
    case soil_moisture_0_to_100cm_mean
    case soil_temperature_0_to_100cm_mean
    case vapor_pressure_deficit_max
    case windgusts_10m_mean
    case windgusts_10m_max
    
    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
    
    var biasCorrectionType: QuantileDeltaMappingBiasCorrection.ChangeType {
        switch self {
        case .et0_fao_evapotranspiration_sum:
            return .relativeChange(maximum: nil)
        case .vapor_pressure_deficit_max:
            return .relativeChange(maximum: nil)
        case .leaf_wetness_probability_mean:
            return .absoluteChage(bounds: 0...100)
        case .soil_moisture_0_to_100cm_mean:
            return .absoluteChage(bounds: 0...10e9)
        case .soil_temperature_0_to_100cm_mean:
            return .absoluteChage(bounds: nil)
        case .windgusts_10m_mean:
            return .relativeChange(maximum: nil)
        case .windgusts_10m_max:
            return .relativeChange(maximum: nil)
        }
    }
}

typealias Cmip6VariableOrDerived = VariableOrDerived<Cmip6Variable, Cmip6VariableDerivedBiasCorrected>

typealias Cmip6VariableOrDerivedPostBias = VariableOrDerived<Cmip6VariableOrDerived, Cmip6VariableDerivedPostBiasCorrection>

extension VariableOrDerived: GenericVariableBiasCorrectable where Derived: GenericVariableBiasCorrectable, Raw: GenericVariableBiasCorrectable {
    var biasCorrectionType: QuantileDeltaMappingBiasCorrection.ChangeType {
        switch self {
        case .raw(let raw):
            return raw.biasCorrectionType
        case .derived(let derived):
            return derived.biasCorrectionType
        }
    }
}

extension Sequence where Element == (Float, Float) {
    func rmse() -> Float {
        var count = 0
        var sum = Float(0)
        for v in self {
            sum += abs(v.0 - v.1)
            count += 1
        }
        return sqrt(sum / Float(count))
    }
    func meanError() -> Float {
        var count = 0
        var sum = Float(0)
        for v in self {
            sum += v.0 - v.1
            count += 1
        }
        return sum / Float(count)
    }
}

extension Sequence where Element == Float {
    func accumulateCount(below threshold: Float) -> [Float] {
        var count: Float = 0
        return self.map( {
            if $0 < threshold {
                count += 1
            }
            return count
        })
    }
}

/// Apply bias correction to raw variables
struct Cmip6BiasCorrectorEra5Seamless: GenericReaderProtocol {
    typealias MixingVar = Cmip6VariableOrDerived
    
    typealias Domain = Cmip6Domain
    
    var modelLat: Float { readerEra5Land?.modelLat ?? readerEra5.modelLat }
    
    var modelLon: Float { readerEra5Land?.modelLon ?? readerEra5.modelLon }
    
    var modelElevation: ElevationOrSea { readerEra5Land?.modelElevation ?? readerEra5.modelElevation }
    
    var targetElevation: Float { reader.targetElevation }
    
    var modelDtSeconds: Int { reader.modelDtSeconds }
    
    var domain: Domain { reader.domain }
    
    /// cmip reader
    let reader: Cmip6ReaderPreBiasCorrection<GenericReader<Cmip6Domain, Cmip6Variable>>
    
    /// era5 reader
    let readerEra5: GenericReader<CdsDomain, Era5Variable>
    
    /// era5 land reader
    let readerEra5Land: GenericReader<CdsDomain, Era5Variable>?
    
    func getStatic(type: ReaderStaticVariable) throws -> Float? {
        return try readerEra5.getStatic(type: type) ?? readerEra5.getStatic(type: type)
    }
    
    /// Get Bias correction field from era5-land or era5
    func getEra5BiasCorrectionWeights(for variable: Cmip6VariableOrDerived) throws -> (weights: BiasCorrectionSeasonalLinear, modelElevation: Float) {
        if let readerEra5Land, let variable = Era5DailyWeatherVariable(rawValue: variable.rawValue), let referenceWeightFile = try readerEra5Land.domain.openBiasCorrectionFile(for: variable.rawValue) {
            let weights = try referenceWeightFile.read(dim0Slow: readerEra5Land.position..<readerEra5Land.position+1, dim1: 0..<referenceWeightFile.dim1)
            if !weights.containsNaN() {
                return (BiasCorrectionSeasonalLinear(meansPerYear: weights), readerEra5Land.modelElevation.numeric)
            }
        }
        guard let variable = Era5DailyWeatherVariable(rawValue: variable.rawValue), let referenceWeightFile = try readerEra5.domain.openBiasCorrectionFile(for: variable.rawValue) else {
            throw ForecastapiError.generic(message: "Could not read reference weight file \(variable) for domain \(readerEra5.domain)")
        }
        let weights = try referenceWeightFile.read(dim0Slow: readerEra5.position..<readerEra5.position+1, dim1: 0..<referenceWeightFile.dim1)
        return (BiasCorrectionSeasonalLinear(meansPerYear: weights), readerEra5.modelElevation.numeric)
    }
    
    
    func get(variable: Cmip6VariableOrDerived, time: TimerangeDt) throws -> DataAndUnit {
        let raw = try reader.get(variable: variable, time: time)
        var data = raw.data
        
        guard let controlWeightFile = try reader.domain.openBiasCorrectionFile(for: variable.rawValue) else {
            throw ForecastapiError.generic(message: "Could not read reference weight file \(variable) for domain \(reader.domain)")
        }
        let controlWeights = BiasCorrectionSeasonalLinear(meansPerYear: try controlWeightFile.read(dim0Slow: reader.reader.position..<reader.reader.position+1, dim1: 0..<controlWeightFile.dim1))
        let referenceWeights = try getEra5BiasCorrectionWeights(for: variable)
        referenceWeights.weights.applyOffset(on: &data, otherWeights: controlWeights, time: time, type: variable.biasCorrectionType)
        if let bounds = variable.biasCorrectionType.bounds {
            for i in data.indices {
                data[i] = Swift.min(Swift.max(data[i], bounds.lowerBound), bounds.upperBound)
            }
        }
        if case let .raw(raw) = variable {
            let isElevationCorrectable = raw == .temperature_2m_max || raw == .temperature_2m_min || raw == .temperature_2m_mean
            let modelElevation = referenceWeights.modelElevation
            if isElevationCorrectable && raw.unit == .celsius && !modelElevation.isNaN && !targetElevation.isNaN && targetElevation != modelElevation {
                for i in data.indices {
                    // correct temperature by 0.65° per 100 m elevation
                    data[i] += (modelElevation - targetElevation) * 0.0065
                }
            }
        }
        return DataAndUnit(data, raw.unit)
    }
    
    func prefetchData(variable: Cmip6VariableOrDerived, time: TimerangeDt) throws {
        try reader.prefetchData(variable: variable, time: time)
    }
    
    func prefetchData(variables: [Cmip6VariableOrDerived], time: TimerangeDt) throws {
        for variable in variables {
            try prefetchData(variable: variable, time: time)
        }
    }
    
    init?(domain: Cmip6Domain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode) throws {
        guard let reader = try GenericReader<Cmip6Domain, Cmip6Variable>(domain: domain, lat: lat, lon: lon, elevation: elevation, mode: mode) else {
            return nil
        }
        guard let readerEra5Land = try GenericReader<CdsDomain, Era5Variable>(domain: .era5_land, lat: lat, lon: lon, elevation: elevation, mode: mode) else {
            return nil
        }
        guard let readerEra5 = try GenericReader<CdsDomain, Era5Variable>(domain: .era5, lat: lat, lon: lon, elevation: elevation, mode: mode) else {
            return nil
        }
        self.reader = Cmip6ReaderPreBiasCorrection(reader: reader, domain: domain)
        /// No data on sea for ERA5-Land
        self.readerEra5Land = readerEra5Land.modelElevation.isSea ? nil : readerEra5Land
        self.readerEra5 = readerEra5
    }
}

/**
 Perform bias correction using another domain (reference domain). Interpolate weights
 */
final class Cmip6BiasCorrectorInterpolatedWeights: GenericReaderProtocol {
    typealias MixingVar = Cmip6VariableOrDerived
    
    typealias Domain = Cmip6Domain
    
    var modelLat: Float { reader.modelLat }
    
    var modelLon: Float { reader.modelLon }
    
    var modelElevation: ElevationOrSea { reader.modelElevation }
    
    var targetElevation: Float { reader.targetElevation }
    
    var modelDtSeconds: Int { reader.modelDtSeconds }
    
    var domain: Domain { reader.domain }
    
    /// cmip reader
    let reader: Cmip6ReaderPreBiasCorrection<GenericReader<Cmip6Domain, Cmip6Variable>>
    
    /// imerg grid point
    let referencePosition: GridPoint2DFraction
    
    let referenceDomain: GenericDomain
    
    var _referenceElevation: ElevationOrSea? = nil
    
    func getStatic(type: ReaderStaticVariable) throws -> Float? {
        throw ForecastapiError.generic(message: "Cmip6BiasCorrectorInterpolatedWeights does not support static files")
    }
    
    func getReferenceElevation() throws -> ElevationOrSea {
        if let _referenceElevation {
            return _referenceElevation
        }
        guard let elevationFile = referenceDomain.getStaticFile(type: .elevation) else {
            throw ForecastapiError.generic(message: "Elevation file for domain \(referenceDomain) is missing")
        }
        let referenceElevation = try referenceDomain.grid.readElevationInterpolated(gridpoint: referencePosition, elevationFile: elevationFile)
        self._referenceElevation = referenceElevation
        return referenceElevation
    }
    
    func get(variable: Cmip6VariableOrDerived, time: TimerangeDt) throws -> DataAndUnit {
        let raw = try reader.get(variable: variable, time: time)
        var data = raw.data
        
        guard let controlWeightFile = try reader.domain.openBiasCorrectionFile(for: variable.rawValue) else {
            throw ForecastapiError.generic(message: "Could not read reference weight file \(variable) for domain \(reader.domain)")
        }
        let controlWeights = BiasCorrectionSeasonalLinear(meansPerYear: try controlWeightFile.read(dim0Slow: reader.reader.position..<reader.reader.position+1, dim1: 0..<controlWeightFile.dim1))
        
        guard let referenceVariable = Era5DailyWeatherVariable(rawValue: variable.rawValue), let referenceWeightFile = try referenceDomain.openBiasCorrectionFile(for: referenceVariable.rawValue) else {
            throw ForecastapiError.generic(message: "Could not read reference weight file \(variable) for domain \(referenceDomain)")
        }
        let referenceWeights = BiasCorrectionSeasonalLinear(meansPerYear: try referenceWeightFile.readInterpolated(dim0: referencePosition, dim0Nx: referenceDomain.grid.nx, dim1: 0..<referenceWeightFile.dim1))
        
        referenceWeights.applyOffset(on: &data, otherWeights: controlWeights, time: time, type: variable.biasCorrectionType)
        if let bounds = variable.biasCorrectionType.bounds {
            for i in data.indices {
                data[i] = Swift.min(Swift.max(data[i], bounds.lowerBound), bounds.upperBound)
            }
        }
        if case let .raw(raw) = variable {
            let isElevationCorrectable = raw == .temperature_2m_max || raw == .temperature_2m_min || raw == .temperature_2m_mean
            
            if isElevationCorrectable && raw.unit == .celsius && !targetElevation.isNaN {
                let modelElevation = try getReferenceElevation().numeric
                if !modelElevation.isNaN && targetElevation != modelElevation {
                    for i in data.indices {
                        // correct temperature by 0.65° per 100 m elevation
                        data[i] += (modelElevation - targetElevation) * 0.0065
                    }
                }
            }
        }
        return DataAndUnit(data, raw.unit)
    }
    
    func prefetchData(variable: Cmip6VariableOrDerived, time: TimerangeDt) throws {
        try reader.prefetchData(variable: variable, time: time)
    }
    
    init?(domain: Cmip6Domain, referenceDomain: GenericDomain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode) throws {
        guard let reader = try GenericReader<Cmip6Domain, Cmip6Variable>(domain: domain, lat: lat, lon: lon, elevation: elevation, mode: mode) else {
            return nil
        }
        guard let referencePosition = referenceDomain.grid.findPointInterpolated(lat: lat, lon: lon) else {
            return nil
        }
        self.referenceDomain = referenceDomain
        self.referencePosition = referencePosition
        self.reader = Cmip6ReaderPreBiasCorrection(reader: reader, domain: domain)
    }
}


/**
 Perform bias correction using another domain
 */
struct Cmip6BiasCorrectorGenericDomain: GenericReaderProtocol {
    typealias MixingVar = Cmip6VariableOrDerived
    
    typealias Domain = Cmip6Domain
    
    var modelLat: Float { reader.modelLat }
    
    var modelLon: Float { reader.modelLon }
    
    var modelElevation: ElevationOrSea { reader.modelElevation }
    
    var targetElevation: Float { reader.targetElevation }
    
    var modelDtSeconds: Int { reader.modelDtSeconds }
    
    var domain: Domain { reader.domain }
    
    /// cmip reader
    let reader: Cmip6ReaderPreBiasCorrection<GenericReader<Cmip6Domain, Cmip6Variable>>
    
    /// imerg grid point
    let referencePosition: Int
    
    let referenceDomain: GenericDomain
    
    let referenceElevation: ElevationOrSea
    
    func getStatic(type: ReaderStaticVariable) throws -> Float? {
        guard let file = referenceDomain.getStaticFile(type: type) else {
            return nil
        }
        return try referenceDomain.grid.readFromStaticFile(gridpoint: referencePosition, file: file)
    }
    
    func get(variable: Cmip6VariableOrDerived, time: TimerangeDt) throws -> DataAndUnit {
        let raw = try reader.get(variable: variable, time: time)
        var data = raw.data
        
        guard let controlWeightFile = try reader.domain.openBiasCorrectionFile(for: variable.rawValue) else {
            throw ForecastapiError.generic(message: "Could not read reference weight file \(variable) for domain \(reader.domain)")
        }
        let controlWeights = BiasCorrectionSeasonalLinear(meansPerYear: try controlWeightFile.read(dim0Slow: reader.reader.position..<reader.reader.position+1, dim1: 0..<controlWeightFile.dim1))
        
        guard let referenceVariable = Era5DailyWeatherVariable(rawValue: variable.rawValue), let referenceWeightFile = try referenceDomain.openBiasCorrectionFile(for: referenceVariable.rawValue) else {
            throw ForecastapiError.generic(message: "Could not read reference weight file \(variable) for domain \(referenceDomain)")
        }
        let referenceWeights = BiasCorrectionSeasonalLinear(meansPerYear: try referenceWeightFile.read(dim0Slow: referencePosition..<referencePosition+1, dim1: 0..<referenceWeightFile.dim1))
        
        referenceWeights.applyOffset(on: &data, otherWeights: controlWeights, time: time, type: variable.biasCorrectionType)
        if let bounds = variable.biasCorrectionType.bounds {
            for i in data.indices {
                data[i] = Swift.min(Swift.max(data[i], bounds.lowerBound), bounds.upperBound)
            }
        }
        if case let .raw(raw) = variable {
            let isElevationCorrectable = raw == .temperature_2m_max || raw == .temperature_2m_min || raw == .temperature_2m_mean
            let modelElevation = referenceElevation.numeric
            if isElevationCorrectable && raw.unit == .celsius && !modelElevation.isNaN && !targetElevation.isNaN && targetElevation != modelElevation {
                for i in data.indices {
                    // correct temperature by 0.65° per 100 m elevation
                    data[i] += (modelElevation - targetElevation) * 0.0065
                }
            }
        }
        return DataAndUnit(data, raw.unit)
    }
    
    func prefetchData(variable: Cmip6VariableOrDerived, time: TimerangeDt) throws {
        try reader.prefetchData(variable: variable, time: time)
    }
    
    init?(domain: Cmip6Domain, referenceDomain: GenericDomain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode) throws {
        guard let reader = try GenericReader<Cmip6Domain, Cmip6Variable>(domain: domain, lat: lat, lon: lon, elevation: elevation, mode: mode) else {
            return nil
        }
        guard let referencePosition = try referenceDomain.grid.findPoint(lat: lat, lon: lon, elevation: elevation, elevationFile: referenceDomain.getStaticFile(type: .elevation), mode: mode) else {
            return nil
        }
        self.referenceDomain = referenceDomain
        self.referenceElevation = referencePosition.gridElevation
        self.referencePosition = referencePosition.gridpoint
        
        self.reader = Cmip6ReaderPreBiasCorrection(reader: reader, domain: domain)
    }
    
    init?(domain: Cmip6Domain, referenceDomain: GenericDomain, referencePosition: Int, referenceElevation: ElevationOrSea) throws {
        
        let (lat, lon) = referenceDomain.grid.getCoordinates(gridpoint: referencePosition)
        guard let reader = try GenericReader<Cmip6Domain, Cmip6Variable>(domain: domain, lat: lat, lon: lon, elevation: referenceElevation.numeric, mode: .nearest) else {
            throw ForecastapiError.noDataAvilableForThisLocation
        }
        self.reader = Cmip6ReaderPreBiasCorrection(reader: reader, domain: domain)
        self.referenceDomain = referenceDomain
        self.referencePosition = referencePosition
        self.referenceElevation = referenceElevation
    }
}

/// There are 2 layers of derived variables
/// "PreBiasCorrected" calculated derived variables before any bias correction
/// "PostBiasCorrected" is done after bias correction
struct Cmip6ReaderPostBiasCorrected<ReaderNext: GenericReaderProtocol>: GenericReaderDerivedSimple, GenericReaderProtocol, Cmip6Readerable where ReaderNext.MixingVar == Cmip6VariableOrDerived {

    typealias Derived = Cmip6VariableDerivedPostBiasCorrection
    
    var reader: ReaderNext
    
    var domain: Cmip6Domain
    
    init(reader: ReaderNext, domain: Cmip6Domain) {
        self.reader = reader
        self.domain = domain
    }

    func get(derived: Cmip6VariableDerivedPostBiasCorrection, time: TimerangeDt) throws -> DataAndUnit {
        switch derived {
        case .snowfall_sum:
            let snowwater = try get(raw: .raw(.snowfall_water_equivalent_sum), time: time).data
            let snowfall = snowwater.map { $0 * 0.7 }
            return DataAndUnit(snowfall, .centimeter)
        case .rain_sum:
            let snowwater = try get(raw: .raw(.snowfall_water_equivalent_sum), time: time)
            let precip = try get(raw: .raw(.precipitation_sum), time: time)
            let rain = zip(precip.data, snowwater.data).map({
                return max($0.0-$0.1, 0)
            })
            return DataAndUnit(rain, precip.unit)
        case .dewpoint_2m_max:
            let tempMin = try get(raw: .raw(.temperature_2m_min), time: time).data
            let tempMax = try get(raw: .raw(.temperature_2m_max), time: time).data
            let rhMax = try get(raw: .raw(.relative_humidity_2m_max), time: time).data
            return DataAndUnit(zip(zip(tempMax, tempMin), rhMax).map(Meteorology.dewpointDaily), .celsius)
        case .dewpoint_2m_min:
            let tempMin = try get(raw: .raw(.temperature_2m_min), time: time).data
            let tempMax = try get(raw: .raw(.temperature_2m_max), time: time).data
            let rhMin = try get(raw: .raw(.relative_humidity_2m_min), time: time).data
            return DataAndUnit(zip(zip(tempMax, tempMin), rhMin).map(Meteorology.dewpointDaily), .celsius)
        case .dewpoint_2m_mean:
            let tempMin = try get(raw: .raw(.temperature_2m_min), time: time).data
            let tempMax = try get(raw: .raw(.temperature_2m_max), time: time).data
            let rhMean = try get(raw: .raw(.relative_humidity_2m_mean), time: time).data
            return DataAndUnit(zip(zip(tempMax, tempMin), rhMean).map(Meteorology.dewpointDaily), .celsius)
        case .growing_degree_days_base_0_limit_50:
            let base: Float = 0
            let limit: Float = 50
            let tempmax = try get(raw: .raw(.temperature_2m_max), time: time).data
            let tempmin = try get(raw: .raw(.temperature_2m_min), time: time).data
            return DataAndUnit(zip(tempmax, tempmin).map({ (tmax, tmin) in
                max(min((tmax - tmin) / 2, limit) - base, 0)
            }), .gddCelsius)
        }
    }
    
    func prefetchData(derived: Cmip6VariableDerivedPostBiasCorrection, time: TimerangeDt) throws {
        switch derived {
        case .snowfall_sum:
            try prefetchData(raw: .raw(.snowfall_water_equivalent_sum), time: time)
        case .rain_sum:
            try prefetchData(raw: .raw(.precipitation_sum), time: time)
            try prefetchData(raw: .raw(.snowfall_water_equivalent_sum), time: time)
        case .dewpoint_2m_max:
            try prefetchData(raw: .raw(.temperature_2m_min), time: time)
            try prefetchData(raw: .raw(.relative_humidity_2m_max), time: time)
        case .dewpoint_2m_min:
            try prefetchData(raw: .raw(.temperature_2m_max), time: time)
            try prefetchData(raw: .raw(.relative_humidity_2m_min), time: time)
        case .dewpoint_2m_mean:
            try prefetchData(raw: .raw(.temperature_2m_mean), time: time)
            try prefetchData(raw: .raw(.relative_humidity_2m_mean), time: time)
        case .growing_degree_days_base_0_limit_50:
            try prefetchData(raw: .raw(.temperature_2m_max), time: time)
            try prefetchData(raw: .raw(.temperature_2m_min), time: time)
        }
    }
}

/// Raw input is used and bias correction is performed afterwards
struct Cmip6ReaderPreBiasCorrection<ReaderNext: GenericReaderProtocol>: GenericReaderDerivedSimple, GenericReaderProtocol where ReaderNext.MixingVar == Cmip6Variable {

    typealias Derived = Cmip6VariableDerivedBiasCorrected
    
    var reader: ReaderNext
    
    var domain: Cmip6Domain
    
    init(reader: ReaderNext, domain: Cmip6Domain) {
        self.reader = reader
        self.domain = domain
    }

    func get(derived: Cmip6VariableDerivedBiasCorrected, time: TimerangeDt) throws -> DataAndUnit {
        switch derived {
        case .et0_fao_evapotranspiration_sum:
            let tempmax = try get(raw: .temperature_2m_max, time: time).data
            let tempmin = try get(raw: .temperature_2m_min, time: time).data
            let tempmean = try get(raw: .temperature_2m_mean, time: time).data
            let wind = try get(raw: .windspeed_10m_mean, time: time).data
            let radiation = try get(raw: .shortwave_radiation_sum, time: time).data
            let exrad = Zensun.extraTerrestrialRadiationBackwards(latitude: reader.modelLat, longitude: reader.modelLon, timerange: time.with(dtSeconds: 3600)).sum(by: 24)
            let hasRhMinMax = !(domain == .FGOALS_f3_H || domain == .HiRAM_SIT_HR || domain == .MPI_ESM1_2_XR || domain == .FGOALS_f3_H)
            let rhmin = hasRhMinMax ? try get(raw: .relative_humidity_2m_min, time: time).data : nil
            let rhmaxOrMean = hasRhMinMax ? try get(raw: .relative_humidity_2m_max, time: time).data : try get(raw: .relative_humidity_2m_mean, time: time).data
            let elevation = reader.targetElevation.isNaN ? reader.modelElevation.numeric : reader.targetElevation
            
            var et0 = [Float]()
            et0.reserveCapacity(tempmax.count)
            for i in tempmax.indices {
                let rh: Meteorology.MaxAndMinOrMean
                if let rhmin {
                    rh = .maxmin(max: rhmaxOrMean[i], min: rhmin[i])
                } else {
                    rh = .mean(mean: rhmaxOrMean[i])
                }
                et0.append(Meteorology.et0EvapotranspirationDaily(
                    temperature2mCelsiusDailyMax: tempmax[i],
                    temperature2mCelsiusDailyMin: tempmin[i],
                    temperature2mCelsiusDailyMean: tempmean[i],
                    windspeed10mMeterPerSecondMean: wind[i],
                    shortwaveRadiationMJSum: radiation[i],
                    elevation: elevation.isNaN ? 0 : elevation,
                    extraTerrestrialRadiationSum: exrad[i] * 0.0036,
                    relativeHumidity: rh))
            }
            return DataAndUnit(et0, .millimeter)
        case .vapor_pressure_deficit_max:
            let tempmax = try get(raw: .temperature_2m_max, time: time).data
            let tempmin = try get(raw: .temperature_2m_min, time: time).data
            let hasRhMinMax = !(domain == .FGOALS_f3_H || domain == .HiRAM_SIT_HR || domain == .MPI_ESM1_2_XR || domain == .FGOALS_f3_H)
            let rhmin = hasRhMinMax ? try get(raw: .relative_humidity_2m_min, time: time).data : nil
            let rhmaxOrMean = hasRhMinMax ? try get(raw: .relative_humidity_2m_max, time: time).data : try get(raw: .relative_humidity_2m_mean, time: time).data
            
            var vpd = [Float]()
            vpd.reserveCapacity(tempmax.count)
            for i in tempmax.indices {
                let rh: Meteorology.MaxAndMinOrMean
                if let rhmin {
                    rh = .maxmin(max: rhmaxOrMean[i], min: rhmin[i])
                } else {
                    rh = .mean(mean: rhmaxOrMean[i])
                }
                vpd.append(Meteorology.vaporPressureDeficitDaily(
                    temperature2mCelsiusDailyMax: tempmax[i],
                    temperature2mCelsiusDailyMin: tempmin[i],
                    relativeHumidity: rh))
            }
            return DataAndUnit(vpd, .kiloPascal)
        case .leaf_wetness_probability_mean:
            let tempmax = try get(raw: .temperature_2m_max, time: time).data
            let tempmin = try get(raw: .temperature_2m_min, time: time).data
            let hasRhMinMax = !(domain == .FGOALS_f3_H || domain == .HiRAM_SIT_HR || domain == .MPI_ESM1_2_XR || domain == .FGOALS_f3_H)
            let rhmin = hasRhMinMax ? try get(raw: .relative_humidity_2m_min, time: time).data : nil
            let rhmaxOrMean = hasRhMinMax ? try get(raw: .relative_humidity_2m_max, time: time).data : try get(raw: .relative_humidity_2m_mean, time: time).data
            let preciptitation = try get(raw: .precipitation_sum, time: time).data
            
            var leafWetness = [Float]()
            leafWetness.reserveCapacity(tempmax.count)
            for i in tempmax.indices {
                let rh: Meteorology.MaxAndMinOrMean
                if let rhmin {
                    rh = .maxmin(max: rhmaxOrMean[i], min: rhmin[i])
                } else {
                    rh = .mean(mean: rhmaxOrMean[i])
                }
                leafWetness.append(Meteorology.leafwetnessPorbabilityDaily(temperature2mCelsiusDaily: (max: tempmax[i], min: tempmin[i]), relativeHumidity: rh, precipitation: preciptitation[i]))
            }
            return DataAndUnit(leafWetness, .percent)
        case .soil_moisture_0_to_100cm_mean:
            // estimate soil moisture in 0-100 by a moving average over 0-10 cm moisture
            let sm0_10 = try get(raw: .soil_moisture_0_to_10cm_mean, time: time)
            let sm10_28 = sm0_10.data.indices.map { return sm0_10.data[max(0, $0-5) ..< $0+1].mean() }
            let sm28_100 = sm10_28.indices.map { return sm10_28[max(0, $0-51) ..< $0+1].mean() }
            return DataAndUnit(zip(sm0_10.data, zip(sm10_28, sm28_100)).map({
                let (sm0_10, (sm10_28, sm28_100)) = $0
                return sm0_10 * 0.1 + sm10_28 * (0.28 - 0.1) + sm28_100 * (1 - 0.28)
            }), sm0_10.unit)
        case .soil_temperature_0_to_100cm_mean:
            let t2m = try get(raw: .temperature_2m_mean, time: time)
            let st0_7 = t2m.data.indices.map { return t2m.data[max(0, $0-3) ..< $0+1].mean() }
            let st7_28 = st0_7.indices.map { return st0_7[max(0, $0-5) ..< $0+1].mean() }
            let st28_100 = st7_28.indices.map { return st7_28[max(0, $0-51) ..< $0+1].mean() }
            return DataAndUnit(zip(st0_7, zip(st7_28, st28_100)).map({
                let (st0_7, (st7_28, st28_100)) = $0
                return st0_7 * 0.07 + st7_28 * (0.28 - 0.07) + st28_100 * (1 - 0.28)
            }), t2m.unit)
        case .windgusts_10m_mean:
            return try get(raw: .windspeed_10m_mean, time: time)
        case .windgusts_10m_max:
            return try get(raw: .windspeed_10m_max, time: time)
        }
    }
    
    func prefetchData(derived: Cmip6VariableDerivedBiasCorrected, time: TimerangeDt) throws {
        switch derived {
        case .et0_fao_evapotranspiration_sum:
            try prefetchData(raw: .temperature_2m_max, time: time)
            try prefetchData(raw: .temperature_2m_min, time: time)
            try prefetchData(raw: .temperature_2m_mean, time: time)
            try prefetchData(raw: .windspeed_10m_mean, time: time)
            try prefetchData(raw: .shortwave_radiation_sum, time: time)
            let hasRhMinMax = !(domain == .FGOALS_f3_H || domain == .HiRAM_SIT_HR || domain == .MPI_ESM1_2_XR || domain == .FGOALS_f3_H)
            if hasRhMinMax {
                try prefetchData(raw: .relative_humidity_2m_min, time: time)
                try prefetchData(raw: .relative_humidity_2m_max, time: time)
            } else {
                try prefetchData(raw: .relative_humidity_2m_mean, time: time)
            }
        case .vapor_pressure_deficit_max:
            try prefetchData(raw: .temperature_2m_max, time: time)
            try prefetchData(raw: .temperature_2m_min, time: time)
            let hasRhMinMax = !(domain == .FGOALS_f3_H || domain == .HiRAM_SIT_HR || domain == .MPI_ESM1_2_XR || domain == .FGOALS_f3_H)
            if hasRhMinMax {
                try prefetchData(raw: .relative_humidity_2m_min, time: time)
                try prefetchData(raw: .relative_humidity_2m_max, time: time)
            } else {
                try prefetchData(raw: .relative_humidity_2m_mean, time: time)
            }
        case .leaf_wetness_probability_mean:
            try prefetchData(raw: .temperature_2m_max, time: time)
            try prefetchData(raw: .temperature_2m_min, time: time)
            try prefetchData(raw: .precipitation_sum, time: time)
            let hasRhMinMax = !(domain == .FGOALS_f3_H || domain == .HiRAM_SIT_HR || domain == .MPI_ESM1_2_XR || domain == .FGOALS_f3_H)
            if hasRhMinMax {
                try prefetchData(raw: .relative_humidity_2m_min, time: time)
                try prefetchData(raw: .relative_humidity_2m_max, time: time)
            } else {
                try prefetchData(raw: .relative_humidity_2m_mean, time: time)
            }
        case .soil_moisture_0_to_100cm_mean:
            try prefetchData(raw: .soil_moisture_0_to_10cm_mean, time: time)
        case .soil_temperature_0_to_100cm_mean:
            try prefetchData(raw: .temperature_2m_mean, time: time)
        case .windgusts_10m_mean:
            try prefetchData(raw: .windspeed_10m_mean, time: time)
        case .windgusts_10m_max:
            try prefetchData(raw: .windspeed_10m_max, time: time)
        }
    }
}

struct CmipQuery: Content, QueryWithTimezone, ApiUnitsSelectable {
    let latitude: Float
    let longitude: Float
    //let hourly: [Cmip6VariableOrDerived]?
    let daily: [String]?
    //let current_weather: Bool?
    let elevation: Float?
    //let timezone: String?
    let temperature_unit: TemperatureUnit?
    let windspeed_unit: WindspeedUnit?
    let precipitation_unit: PrecipitationUnit?
    let timeformat: Timeformat?
    let format: ForecastResultFormat?
    let cell_selection: GridSelectionMode?
    let disable_bias_correction: Bool?
    
    /// not used, because only daily data
    let timezone: String?
    let models: [String]?
    
    /// iso starting date `2022-02-01`
    let start_date: IsoDate
    /// included end date `2022-06-01`
    let end_date: IsoDate
    
    func validate() throws {
        if latitude > 90 || latitude < -90 || latitude.isNaN {
            throw ForecastapiError.latitudeMustBeInRangeOfMinus90to90(given: latitude)
        }
        if longitude > 180 || longitude < -180 || longitude.isNaN {
            throw ForecastapiError.longitudeMustBeInRangeOfMinus180to180(given: longitude)
        }
        guard end_date.date >= start_date.date else {
            throw ForecastapiError.enddateMustBeLargerEqualsThanStartdate
        }
        guard start_date.year >= 1950, start_date.year <= 2050 else {
            throw ForecastapiError.dateOutOfRange(parameter: "start_date", allowed: Timestamp(1950,1,1)..<Timestamp(2050,1,1))
        }
        guard end_date.year >= 1950, end_date.year <= 2050 else {
            throw ForecastapiError.dateOutOfRange(parameter: "end_date", allowed: Timestamp(1950,1,1)..<Timestamp(2050,1,1))
        }
        //if daily?.count ?? 0 > 0 && timezone == nil {
            //throw ForecastapiError.timezoneRequired
        //}
    }
    
    func getTimerange(allowedRange: Range<Timestamp>) throws -> TimerangeLocal {
        let start = start_date.toTimestamp()
        let includedEnd = end_date.toTimestamp()
        guard includedEnd.timeIntervalSince1970 >= start.timeIntervalSince1970 else {
            throw ForecastapiError.enddateMustBeLargerEqualsThanStartdate
        }
        guard allowedRange.contains(start) else {
            throw ForecastapiError.dateOutOfRange(parameter: "start_date", allowed: allowedRange)
        }
        guard allowedRange.contains(includedEnd) else {
            throw ForecastapiError.dateOutOfRange(parameter: "end_date", allowed: allowedRange)
        }
        return TimerangeLocal(range: start ..< includedEnd.add(86400), utcOffsetSeconds: 0)
    }
    
    var timeformatOrDefault: Timeformat {
        return timeformat ?? .iso8601
    }
    
    /*func getUtcOffsetSeconds() throws -> Int {
        guard let timezone = timezone else {
            return 0
        }
        guard let tz = TimeZone(identifier: timezone) else {
            throw ForecastapiError.invalidTimezone
        }
        return (tz.secondsFromGMT() / 3600) * 3600
    }*/
}
