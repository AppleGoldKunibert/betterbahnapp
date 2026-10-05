import Foundation

/// Larger towns, so station search can ask for "Berlin ost" when the user is in Berlin: the
/// geocoder only returns its 50 best text matches ("Ulm Ost", "Ostrava", …) for "ost", however
/// near the place bias, and Berlin Ostbahnhof isn't among them. Kept on the device, so the user's
/// coordinates never leave it; only the town's name goes out with the search text.
enum NearbyTowns {
    /// How far from a town's centre the user still counts as being in it.
    static let radius: Double = 25_000

    /// The nearest town within `radius` of `location`, if any.
    static func town(near location: Coordinate) -> String? {
        let nearest = towns.min { location.distance(to: $0.coordinate) < location.distance(to: $1.coordinate) }
        guard let nearest, location.distance(to: nearest.coordinate) < radius else { return nil }
        return nearest.name
    }

    private static func town(_ name: String, _ latitude: Double, _ longitude: Double) -> (name: String, coordinate: Coordinate) {
        (name, Coordinate(latitude: latitude, longitude: longitude))
    }

    /// German towns of about 100,000 people and more, and the big towns of Austria and Switzerland,
    /// by the name the geocoder knows them by.
    static let towns = [
        town("Berlin", 52.520, 13.405), town("Hamburg", 53.551, 9.994), town("München", 48.137, 11.576),
        town("Köln", 50.938, 6.960), town("Frankfurt", 50.111, 8.682), town("Stuttgart", 48.776, 9.183),
        town("Düsseldorf", 51.227, 6.774), town("Leipzig", 51.340, 12.375), town("Dortmund", 51.514, 7.466),
        town("Essen", 51.456, 7.012), town("Bremen", 53.079, 8.802), town("Dresden", 51.050, 13.738),
        town("Hannover", 52.376, 9.738), town("Nürnberg", 49.452, 11.077), town("Duisburg", 51.435, 6.763),
        town("Bochum", 51.482, 7.216), town("Wuppertal", 51.256, 7.151), town("Bielefeld", 52.022, 8.532),
        town("Bonn", 50.737, 7.098), town("Münster", 51.961, 7.626), town("Mannheim", 49.487, 8.466),
        town("Karlsruhe", 49.007, 8.404), town("Augsburg", 48.371, 10.898), town("Wiesbaden", 50.078, 8.240),
        town("Mönchengladbach", 51.180, 6.443), town("Gelsenkirchen", 51.518, 7.086), town("Aachen", 50.776, 6.084),
        town("Braunschweig", 52.269, 10.521), town("Kiel", 54.323, 10.123), town("Chemnitz", 50.828, 12.921),
        town("Halle", 51.483, 11.970), town("Magdeburg", 52.121, 11.628), town("Freiburg", 47.999, 7.842),
        town("Krefeld", 51.339, 6.586), town("Mainz", 49.993, 8.247), town("Lübeck", 53.866, 10.686),
        town("Erfurt", 50.978, 11.029), town("Oberhausen", 51.470, 6.866), town("Rostock", 54.092, 12.099),
        town("Kassel", 51.312, 9.480), town("Hagen", 51.367, 7.463), town("Potsdam", 52.396, 13.058),
        town("Saarbrücken", 49.234, 6.995), town("Hamm", 51.681, 7.820), town("Ludwigshafen", 49.477, 8.445),
        town("Oldenburg", 53.141, 8.214), town("Mülheim", 51.432, 6.880), town("Osnabrück", 52.279, 8.047),
        town("Leverkusen", 51.046, 7.004), town("Darmstadt", 49.873, 8.651), town("Heidelberg", 49.399, 8.672),
        town("Solingen", 51.171, 7.083), town("Herne", 51.538, 7.219), town("Neuss", 51.200, 6.692),
        town("Regensburg", 49.013, 12.102), town("Paderborn", 51.719, 8.754), town("Ingolstadt", 48.766, 11.426),
        town("Offenbach", 50.096, 8.766), town("Würzburg", 49.792, 9.953), town("Fürth", 49.477, 10.989),
        town("Ulm", 48.401, 9.988), town("Heilbronn", 49.142, 9.219), town("Pforzheim", 48.892, 8.695),
        town("Wolfsburg", 52.423, 10.787), town("Göttingen", 51.541, 9.916), town("Bottrop", 51.524, 6.929),
        town("Reutlingen", 48.491, 9.204), town("Koblenz", 50.356, 7.594), town("Bremerhaven", 53.540, 8.581),
        town("Recklinghausen", 51.614, 7.198), town("Bergisch Gladbach", 50.992, 7.136), town("Erlangen", 49.590, 11.004),
        town("Jena", 50.927, 11.589), town("Remscheid", 51.179, 7.189), town("Trier", 49.750, 6.637),
        town("Salzgitter", 52.150, 10.333), town("Moers", 51.451, 6.626), town("Siegen", 50.875, 8.024),
        town("Hildesheim", 52.152, 9.951), town("Cottbus", 51.756, 14.333), town("Gütersloh", 51.907, 8.379),
        town("Kaiserslautern", 49.444, 7.769), town("Schwerin", 53.629, 11.415), town("Zwickau", 50.719, 12.496),
        town("Flensburg", 54.794, 9.437), town("Konstanz", 47.660, 9.176), town("Rosenheim", 47.856, 12.128),
        town("Bamberg", 49.898, 10.902), town("Bayreuth", 49.946, 11.578), town("Passau", 48.567, 13.432),
        town("Frankfurt (Oder)", 52.342, 14.551), town("Gera", 50.877, 12.083), town("Fulda", 50.555, 9.680),
        town("Wien", 48.208, 16.373), town("Graz", 47.071, 15.439), town("Linz", 48.306, 14.286),
        town("Salzburg", 47.809, 13.055), town("Innsbruck", 47.269, 11.404), town("Zürich", 47.377, 8.540),
        town("Basel", 47.560, 7.588), town("Bern", 46.948, 7.447), town("Genève", 46.204, 6.143),
        town("Lausanne", 46.520, 6.633), town("Luzern", 47.050, 8.309),
    ]
}
