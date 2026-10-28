import Foundation
import FutureDocument
import FutureEngine

/// A ready-made feed, as the feed setup screen lists it (docs/UI.md, 5.10): a source with its
/// settings filled in, and how to show the readings in a slot of their own.
public struct FeedPreset: Identifiable, Sendable, Hashable {
    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case markets, rates, debt, inflation, climate, migration, health, custom

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .markets: return "Markets"
            case .rates: return "Rates and bonds"
            case .debt: return "Debt"
            case .inflation: return "Inflation"
            case .climate: return "Climate"
            case .migration: return "Migration"
            case .health: return "Disease"
            case .custom: return "Any source"
            }
        }
    }

    public let id: String
    public let title: String
    public let category: Category
    public let summary: String
    /// The source and the settings that pick its readings.
    public let spec: FeedSpec
    /// What the source's numbers are: "percent", "°C above the 1901–2000 average".
    public let units: String
    /// The source gives percent points (4.5 for 4.5%).
    public let percentPoints: Bool
    /// The source gives °F.
    public let fahrenheit: Bool
    /// For a slot of its own: its name, how its values are shown, and its step.
    public let slotName: String
    /// `number`, `percent`, `currency` or `temperature`.
    public let format: String
    /// What the source's money is in, so its slot keeps it whatever the scenario's currency.
    public let currency: Currency?
    public let step: StepRate

    init(_ id: String, _ title: String, _ category: Category, _ summary: String, provider: String,
         _ settings: KeyValuePairs<String, String>, units: String, percentPoints: Bool = false, fahrenheit: Bool = false,
         slot: String, format: String = "number", currency: Currency? = nil, step: StepRate = .days(1)) {
        self.id = id
        self.title = title
        self.category = category
        self.summary = summary
        spec = FeedSpec(title: title, provider: provider, settings: settings.map { FeedSetting($0.key, $0.value) })
        self.units = units
        self.percentPoints = percentPoints
        self.fahrenheit = fahrenheit
        slotName = slot
        self.format = format
        self.currency = currency
        self.step = step
    }

    public var provider: (any FeedProvider)? { FeedProviders.named(spec.provider) }

    /// How the source's numbers become a slot's of this format: percent points become fractions
    /// for a percent, °F becomes °C for a temperature.
    public func conversion(forFormat format: String) -> FeedConversion? {
        if percentPoints && format == "percent" { return .percent }
        if fahrenheit && format == "temperature" { return .fahrenheit }
        return nil
    }

    public static func == (a: FeedPreset, b: FeedPreset) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The ready-made feeds, free sources first (docs/DESIGN.md, 15.8).
public enum FeedCatalog {
    public static func presets(in category: FeedPreset.Category) -> [FeedPreset] {
        all.filter { $0.category == category }
    }

    public static func search(_ text: String) -> [FeedPreset] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { preset in
            let haystack = [preset.title, preset.summary, preset.category.title, preset.provider?.name ?? "", preset.units,
                            preset.spec.query.map(\.value).joined(separator: " ")].joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    public static func preset(id: String) -> FeedPreset? { all.first { $0.id == id } }

    private static let ed = "vutn-jzwm"
    private static let co2 = "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_mm_mlo.csv"

    public static let all: [FeedPreset] = [
        // Markets
        .init("sp500", "S&P 500", .markets, "Daily close of the S&P 500 index. FRED has the last 10 years.",
              provider: "fred", ["series": "SP500"], units: "index points", slot: "SP500"),
        .init("dow", "Dow Jones Industrial Average", .markets, "Daily close. FRED has the last 10 years.",
              provider: "fred", ["series": "DJIA"], units: "index points", slot: "Dow"),
        .init("nasdaq", "NASDAQ Composite", .markets, "Daily close, since 1971.",
              provider: "fred", ["series": "NASDAQCOM"], units: "index points", slot: "Nasdaq"),
        .init("vix", "Volatility (VIX)", .markets, "The CBOE volatility index, daily since 1990.",
              provider: "fred", ["series": "VIXCLS"], units: "index points", slot: "VIX"),
        .init("oil", "Crude oil (WTI)", .markets, "West Texas Intermediate, dollars a barrel, daily since 1986.",
              provider: "fred", ["series": "DCOILWTICO"], units: "US dollars a barrel", slot: "Oil", format: "currency", currency: .usd),
        .init("dollar", "US dollar index", .markets, "The dollar against a broad basket of currencies, daily since 2006.",
              provider: "fred", ["series": "DTWEXBGS"], units: "index, January 2006 = 100", slot: "Dollar"),
        .init("stock", "A stock or fund", .markets, "Any ticker's daily close from Tiingo, back decades. Needs a free key.",
              provider: "tiingo", ["symbol": "SPY", "price": "close"], units: "US dollars", slot: "Stock", format: "currency", currency: .usd),

        // Rates and bonds
        .init("treasury10", "10-year Treasury yield", .rates, "Market yield on 10-year Treasury notes, daily since 1962.",
              provider: "fred", ["series": "DGS10"], units: "percent", percentPoints: true, slot: "Treasury10y", format: "percent"),
        .init("treasury2", "2-year Treasury yield", .rates, "Market yield on 2-year Treasury notes, daily since 1976.",
              provider: "fred", ["series": "DGS2"], units: "percent", percentPoints: true, slot: "Treasury2y", format: "percent"),
        .init("treasury30", "30-year Treasury yield", .rates, "Market yield on 30-year Treasury bonds, daily.",
              provider: "fred", ["series": "DGS30"], units: "percent", percentPoints: true, slot: "Treasury30y", format: "percent"),
        .init("bill3m", "3-month Treasury bill", .rates, "Market yield on 3-month Treasury bills, daily since 1981.",
              provider: "fred", ["series": "DGS3MO"], units: "percent", percentPoints: true, slot: "Bill3m", format: "percent"),
        .init("fedfunds", "Federal funds rate", .rates, "The effective federal funds rate, daily since 1954.",
              provider: "fred", ["series": "DFF"], units: "percent", percentPoints: true, slot: "FedFunds", format: "percent"),
        .init("mortgage30", "30-year mortgage rate", .rates, "Freddie Mac's average 30-year fixed rate, weekly since 1971.",
              provider: "fred", ["series": "MORTGAGE30US"], units: "percent", percentPoints: true, slot: "Mortgage30y",
              format: "percent", step: .weeks(1)),
        .init("bondrate", "Average rate on Treasury bonds", .rates,
              "The Treasury's average interest rate on its outstanding bonds, monthly since 2001.",
              provider: "treasury", ["dataset": "v2/accounting/od/avg_interest_rates", "field": "avg_interest_rate_amt",
                                     "filter": "security_desc:eq:Treasury Bonds"],
              units: "percent", percentPoints: true, slot: "BondRate", format: "percent", step: .months(1)),
        .init("billrate", "Average rate on Treasury bills", .rates,
              "The Treasury's average interest rate on its outstanding bills, monthly since 2001.",
              provider: "treasury", ["dataset": "v2/accounting/od/avg_interest_rates", "field": "avg_interest_rate_amt",
                                     "filter": "security_desc:eq:Treasury Bills"],
              units: "percent", percentPoints: true, slot: "BillRate", format: "percent", step: .months(1)),
        .init("note10price", "10-year note auction price", .rates, "The price of each 10-year note auction, per $100 of face value.",
              provider: "treasury", ["dataset": "v1/accounting/od/auctions_query", "field": "high_price", "date": "auction_date",
                                     "filter": "security_term:eq:10-Year,security_type:eq:Note"],
              units: "US dollars per $100", slot: "Note10Price", format: "currency", currency: .usd, step: .months(1)),
        .init("note10yield", "10-year note auction yield", .rates, "The yield at each 10-year note auction.",
              provider: "treasury", ["dataset": "v1/accounting/od/auctions_query", "field": "high_yield", "date": "auction_date",
                                     "filter": "security_term:eq:10-Year,security_type:eq:Note"],
              units: "percent", percentPoints: true, slot: "Note10Yield", format: "percent", step: .months(1)),
        .init("bond30price", "30-year bond auction price", .rates, "The price of each 30-year bond auction, per $100 of face value.",
              provider: "treasury", ["dataset": "v1/accounting/od/auctions_query", "field": "high_price", "date": "auction_date",
                                     "filter": "security_term:eq:30-Year,security_type:eq:Bond"],
              units: "US dollars per $100", slot: "Bond30Price", format: "currency", currency: .usd, step: .months(1)),

        // Debt
        .init("debt", "US national debt", .debt, "Total public debt outstanding, every working day since 1993: the debt to the penny.",
              provider: "treasury", ["dataset": "v2/accounting/od/debt_to_penny", "field": "tot_pub_debt_out_amt"],
              units: "US dollars", slot: "NationalDebt", format: "currency", currency: .usd),
        .init("debt1790", "US national debt since 1790", .debt, "The debt outstanding at the end of each year, since 1790.",
              provider: "treasury", ["dataset": "v2/accounting/od/debt_outstanding", "field": "debt_outstanding_amt"],
              units: "US dollars", slot: "DebtHistory", format: "currency", currency: .usd, step: .years(1)),
        .init("debtgdp", "US federal debt to GDP", .debt, "Total public debt as a percent of GDP, quarterly since 1966.",
              provider: "fred", ["series": "GFDEGDQ188S"], units: "percent of GDP", percentPoints: true, slot: "DebtToGDP",
              format: "percent", step: .quarters(1)),
        .init("govdebt", "Government debt by country", .debt, "Central government debt as a percent of GDP, yearly, from the World Bank.",
              provider: "worldbank", ["indicator": "GC.DOD.TOTL.GD.ZS", "country": "GBR"], units: "percent of GDP",
              percentPoints: true, slot: "GovDebt", format: "percent", step: .years(1)),

        // Inflation
        .init("cpi", "US consumer prices (CPI)", .inflation, "All-items CPI for urban consumers, monthly, from the Bureau of Labor Statistics.",
              provider: "bls", ["series": "CUUR0000SA0"], units: "index, 1982–84 = 100", slot: "CPI", step: .months(1)),
        .init("corecpi", "US core consumer prices", .inflation, "CPI without food and energy, monthly, from the Bureau of Labor Statistics.",
              provider: "bls", ["series": "CUUR0000SA0L1E"], units: "index, 1982–84 = 100", slot: "CoreCPI", step: .months(1)),
        .init("usinflation", "US inflation rate", .inflation, "The change in consumer prices from a year before, monthly since 1948.",
              provider: "fred", ["series": "CPIAUCSL", "units": "pc1"], units: "percent", percentPoints: true, slot: "Inflation",
              format: "percent", step: .months(1)),
        .init("euroinflation", "Euro area inflation", .inflation, "The change in the euro area's HICP from a year before, monthly.",
              provider: "fred", ["series": "CP0000EZ19M086NEST", "units": "pc1"], units: "percent", percentPoints: true,
              slot: "EuroInflation", format: "percent", step: .months(1)),
        .init("inflation", "Inflation by country", .inflation, "Consumer price inflation for any country, yearly, from the World Bank.",
              provider: "worldbank", ["indicator": "FP.CPI.TOTL.ZG", "country": "USA"], units: "percent", percentPoints: true,
              slot: "Inflation", format: "percent", step: .years(1)),

        // Climate
        .init("globaltemp", "Global temperature", .climate,
              "Land and ocean, monthly since 1850, as a departure from the 1901–2000 average. From NOAA.",
              provider: "noaa", ["series": "global/time-series/globe/land_ocean/1/0"], units: "°C above the 1901–2000 average",
              slot: "GlobalTemp", format: "temperature", step: .months(1)),
        .init("nhemtemp", "Northern Hemisphere temperature", .climate, "Land and ocean, monthly since 1850, from NOAA.",
              provider: "noaa", ["series": "global/time-series/nhem/land_ocean/1/0"], units: "°C above the 1901–2000 average",
              slot: "NorthTemp", format: "temperature", step: .months(1)),
        .init("europetemp", "Europe's temperature", .climate, "Over land, monthly since 1910, from NOAA. Other continents are in its settings.",
              provider: "noaa", ["series": "global/time-series/europe/land/1/0"], units: "°C above the 1901–2000 average",
              slot: "EuropeTemp", format: "temperature", step: .months(1)),
        .init("ustemp", "US temperature", .climate, "The contiguous US's average temperature, monthly since 1895, from NOAA.",
              provider: "noaa", ["series": "national/time-series/110/tavg/1/0"], units: "°F", fahrenheit: true, slot: "USTemp",
              format: "temperature", step: .months(1)),
        .init("statetemp", "A US state's temperature", .climate, "A state's average temperature, monthly since 1895. California to start.",
              provider: "noaa", ["series": "statewide/time-series/4/tavg/1/0"], units: "°F", fahrenheit: true, slot: "StateTemp",
              format: "temperature", step: .months(1)),
        .init("placetemp", "Temperature at a place", .climate, "The daily mean temperature anywhere, from Open-Meteo. London to start.",
              provider: "openmeteo", ["latitude": "51.51", "longitude": "-0.13", "variable": "temperature_2m_mean", "from": "1990-01-01"],
              units: "°C", slot: "LocalTemp", format: "temperature"),
        .init("placerain", "Rain at a place", .climate, "Daily rain and snow anywhere, in millimetres, from Open-Meteo.",
              provider: "openmeteo", ["latitude": "51.51", "longitude": "-0.13", "variable": "precipitation_sum", "from": "1990-01-01"],
              units: "mm", slot: "Rain"),
        .init("co2", "Carbon dioxide in the air", .climate, "Monthly CO₂ at Mauna Loa since 1958, in parts per million, from NOAA.",
              provider: "csv", ["url": co2, "year": "year", "month": "month", "value": "average", "missing": "-99.99"],
              units: "parts per million", slot: "CO2", step: .months(1)),

        // Migration
        .init("netmigration", "Net migration by country", .migration, "People arriving minus people leaving, yearly, from the World Bank.",
              provider: "worldbank", ["indicator": "SM.POP.NETM", "country": "USA"], units: "people", slot: "NetMigration",
              step: .years(1)),
        .init("migrants", "Migrants living in a country", .migration, "The international migrant stock, every five years, from the World Bank.",
              provider: "worldbank", ["indicator": "SM.POP.TOTL", "country": "USA"], units: "people", slot: "Migrants",
              step: .years(1)),
        .init("population", "Population by country", .migration, "Total population, yearly, from the World Bank.",
              provider: "worldbank", ["indicator": "SP.POP.TOTL", "country": "USA"], units: "people", slot: "Population",
              step: .years(1)),

        // Disease
        .init("edflu", "Emergency visits for flu", .health,
              "The share of emergency department visits for flu, weekly since 2023, for the US or a state (geography). From the CDC.",
              provider: "socrata", ["dataset": ed, "date": "week_end", "value": "percent_visits",
                                    "where": "pathogen = 'Influenza' AND geography = 'United States'"],
              units: "percent of visits", percentPoints: true, slot: "FluVisits", format: "percent", step: .weeks(1)),
        .init("edcovid", "Emergency visits for COVID-19", .health,
              "The share of emergency department visits for COVID-19, weekly since 2023, for the US or a state. From the CDC.",
              provider: "socrata", ["dataset": ed, "date": "week_end", "value": "percent_visits",
                                    "where": "pathogen = 'COVID-19' AND geography = 'United States'"],
              units: "percent of visits", percentPoints: true, slot: "CovidVisits", format: "percent", step: .weeks(1)),
        .init("edrsv", "Emergency visits for RSV", .health,
              "The share of emergency department visits for RSV, weekly since 2023, for the US or a state. From the CDC.",
              provider: "socrata", ["dataset": ed, "date": "week_end", "value": "percent_visits",
                                    "where": "pathogen = 'RSV' AND geography = 'United States'"],
              units: "percent of visits", percentPoints: true, slot: "RSVVisits", format: "percent", step: .weeks(1)),
        .init("fluhospital", "People in hospital with flu", .health,
              "Patients with confirmed flu, weekly, for the US (USA) or a state (CA, TX…). From the CDC's NHSN.",
              provider: "socrata", ["dataset": "ua7e-t2fy", "date": "weekendingdate", "value": "totalconffluhosppats",
                                    "where": "jurisdiction = 'USA'"],
              units: "patients", slot: "FluPatients", step: .weeks(1)),
        .init("wastewaterflu", "Flu A in wastewater", .health,
              "The CDC's wastewater viral activity level for influenza A, averaged across a state's sites each week.",
              provider: "socrata", ["dataset": "atcp-73re", "date": "week_end", "value": "avg(site_wval)",
                                    "where": "pathogen_target = 'Influenza A virus' AND state_territory = 'California'"],
              units: "viral activity level", slot: "FluWastewater", step: .weeks(1)),
        .init("wastewatercovid", "COVID-19 in wastewater", .health,
              "The CDC's wastewater viral activity level for SARS-CoV-2, averaged across a state's sites each week.",
              provider: "socrata", ["dataset": "atcp-73re", "date": "week_end", "value": "avg(site_wval)",
                                    "where": "pathogen_target = 'SARS-CoV-2' AND state_territory = 'California'"],
              units: "viral activity level", slot: "CovidWastewater", step: .weeks(1)),
        .init("tuberculosis", "Tuberculosis by country", .health, "New cases a year per 100,000 people, from the World Bank.",
              provider: "worldbank", ["indicator": "SH.TBS.INCD", "country": "IND"], units: "cases per 100,000 people",
              slot: "Tuberculosis", step: .years(1)),
        .init("malaria", "Malaria by country", .health, "New cases a year per 1,000 people at risk, from the World Bank.",
              provider: "worldbank", ["indicator": "SH.MLR.INCD.P3", "country": "NGA"], units: "cases per 1,000 people at risk",
              slot: "Malaria", step: .years(1)),

        // Any source
        .init("anyfred", "Any FRED series", .custom, "Any of FRED's 800,000 series, by its ID.",
              provider: "fred", ["series": ""], units: "as the series says", slot: "Series"),
        .init("anyworldbank", "Any World Bank indicator", .custom, "Any indicator for any country, by its code.",
              provider: "worldbank", ["indicator": "", "country": "USA"], units: "as the indicator says", slot: "Indicator",
              step: .years(1)),
        .init("anybls", "Any BLS series", .custom, "Any Bureau of Labor Statistics series, by its ID.",
              provider: "bls", ["series": ""], units: "as the series says", slot: "Series", step: .months(1)),
        .init("anytreasury", "Any Fiscal Data dataset", .custom, "Any US Treasury Fiscal Data dataset and field.",
              provider: "treasury", ["dataset": "", "field": ""], units: "as the dataset says", slot: "Treasury"),
        .init("anysocrata", "Any open data portal", .custom, "A dataset on data.cdc.gov or another Socrata portal.",
              provider: "socrata", ["domain": "data.cdc.gov", "dataset": "", "date": "", "value": ""], units: "as the dataset says",
              slot: "Data"),
        .init("anycsv", "CSV at a web address", .custom, "Any CSV file with a date column and a value column.",
              provider: "csv", ["url": ""], units: "as the file says", slot: "Data"),
        .init("anyjson", "JSON at a web address", .custom, "Any JSON with dates and values.",
              provider: "json", ["url": ""], units: "as the source says", slot: "Data"),
    ]
}
