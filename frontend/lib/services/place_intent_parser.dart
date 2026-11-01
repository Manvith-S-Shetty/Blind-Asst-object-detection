import 'package:blind_assistant/models/place.dart';

/// Represents a parsed intent to search for nearby geographical places.
class PlaceIntent {
  final PlaceCategory category;
  final String? customSearchTerm;
  final String query;

  const PlaceIntent({
    required this.category,
    this.customSearchTerm,
    required this.query,
  });

  @override
  String toString() => 'PlaceIntent(category: $category, customSearchTerm: $customSearchTerm)';
}

/// Parses voice command transcriptions into structured [PlaceIntent]s.
///
/// Disambiguation Guarantee:
/// Strictly distinguishes between camera-based obstacle searches (e.g. "where is my chair",
/// "find the cup") and geographical place searches (e.g. "find a restaurant near me",
/// "find the nearest pharmacy", "find bus stop nearby").
class PlaceIntentParser {
  /// Detects if the user wants to hear the next nearby place in the current results list.
  static bool isNextIntent(String rawText) {
    final lower = rawText.trim().toLowerCase();
    if (lower.isEmpty) return false;

    return lower == 'next' ||
        lower == 'next place' ||
        lower == 'next result' ||
        lower == 'next one' ||
        lower == 'tell me next' ||
        lower == 'tell me the next' ||
        lower == 'tell me next result' ||
        lower == 'tell me the next result' ||
        lower == 'read next' ||
        lower == 'read the next' ||
        lower == "what's next" ||
        lower == 'whats next' ||
        lower.startsWith('next ');
  }

  /// Detects if the user wants to repeat the current nearby place announcement.
  static bool isRepeatIntent(String rawText) {
    final lower = rawText.trim().toLowerCase();
    if (lower.isEmpty) return false;

    return lower == 'repeat' ||
        lower == 'repeat place' ||
        lower == 'repeat result' ||
        lower == 'repeat that' ||
        lower == 'repeat the place' ||
        lower == 'repeat the result' ||
        lower == 'say again' ||
        lower == 'say that again' ||
        lower == 'tell me again' ||
        lower == 'what did you say' ||
        lower == 'what was that' ||
        lower.startsWith('repeat ');
  }

  static PlaceIntent? parse(String rawText) {
    final lower = rawText.trim().toLowerCase();
    if (lower.isEmpty) return null;

    final hasLocationMarker = lower.contains('near me') ||
        lower.contains('nearby') ||
        lower.contains('nearest') ||
        lower.contains('around here') ||
        lower.contains('close by');

    // 1. Restaurant / Food / Dining
    if (lower.contains('restaurant') ||
        lower.contains('food') ||
        lower.contains('diner') ||
        lower.contains('lunch') ||
        lower.contains('dinner') ||
        lower.contains('pizza') ||
        lower.contains('burger') ||
        lower.contains('bakery') ||
        (hasLocationMarker && lower.contains('eat'))) {
      return PlaceIntent(category: PlaceCategory.restaurant, query: rawText);
    }

    // 2. Clinic / Doctor / Health Center
    if (lower.contains('clinic') ||
        lower.contains('doctor') ||
        lower.contains('dispensary') ||
        lower.contains('health center') ||
        lower.contains('medical center')) {
      return PlaceIntent(category: PlaceCategory.clinic, query: rawText);
    }

    // 3. Hospital / Emergency / Healthcare
    if (lower.contains('hospital') ||
        lower.contains('emergency room') ||
        lower.contains('urgent care')) {
      return PlaceIntent(category: PlaceCategory.hospital, query: rawText);
    }

    // 4. Pharmacy / Chemist / Drugstore / Medicine
    if (lower.contains('pharmacy') ||
        lower.contains('chemist') ||
        lower.contains('drugstore') ||
        lower.contains('medicine') ||
        lower.contains('medical store')) {
      return PlaceIntent(category: PlaceCategory.pharmacy, query: rawText);
    }

    // 5. Bus Stop / Public Transit / Bus Station
    if (lower.contains('bus stop') ||
        lower.contains('bus station') ||
        lower.contains('bus stand') ||
        lower.contains('transit stop') ||
        (hasLocationMarker && lower.contains('bus'))) {
      return PlaceIntent(category: PlaceCategory.busStop, query: rawText);
    }

    // 6. Railway / Train / Metro / Subway
    if (lower.contains('railway') ||
        lower.contains('train station') ||
        lower.contains('train stop') ||
        lower.contains('metro station') ||
        lower.contains('subway') ||
        (hasLocationMarker && (lower.contains('train') || lower.contains('rail')))) {
      return PlaceIntent(category: PlaceCategory.railwayStation, query: rawText);
    }

    // 7. Petrol / Gas / Fuel Station
    if (lower.contains('petrol') ||
        lower.contains('gas station') ||
        lower.contains('fuel station') ||
        lower.contains('gas pump') ||
        (hasLocationMarker && lower.contains('fuel'))) {
      return PlaceIntent(category: PlaceCategory.petrolStation, query: rawText);
    }

    // 5. Shops / Retail / Store / Market
    if (lower.contains('shop') ||
        lower.contains('store') ||
        lower.contains('retail') ||
        lower.contains('clothing') ||
        lower.contains('bookstore') ||
        lower.contains('mall')) {
      return PlaceIntent(category: PlaceCategory.shop, query: rawText);
    }

    // 6. Coffee shop / Cafe / Tea
    if (lower.contains('coffee') ||
        lower.contains('cafe') ||
        lower.contains('café') ||
        lower.contains('tea') ||
        lower.contains('starbucks')) {
      return PlaceIntent(category: PlaceCategory.cafe, query: rawText);
    }

    // 7. Grocery / Supermarket / Market
    if (lower.contains('grocery') ||
        lower.contains('supermarket') ||
        (hasLocationMarker && (lower.contains('market') || lower.contains('mart')))) {
      return PlaceIntent(category: PlaceCategory.grocery, query: rawText);
    }

    // 8. Bank / ATM / Cash
    if (lower.contains('atm') ||
        (hasLocationMarker && (lower.contains('bank') || lower.contains('cash')))) {
      return PlaceIntent(category: PlaceCategory.bank, query: rawText);
    }

    // 9. General places when location markers are explicitly spoken
    if (hasLocationMarker) {
      if (lower.contains('place') || lower.contains('what is')) {
        return PlaceIntent(category: PlaceCategory.general, query: rawText);
      }

      // Extract custom search term from phrase (e.g. "find library near me")
      String term = lower;
      for (final prefix in [
        'find a',
        'find the',
        'find',
        'locate a',
        'locate the',
        'locate',
        'where is the nearest',
        'where is a nearest',
        'where is the',
        'where is a',
        'where is',
        'search for a',
        'search for the',
        'search for',
      ]) {
        if (term.startsWith(prefix)) {
          term = term.substring(prefix.length).trim();
          break;
        }
      }

      term = term
          .replaceAll('near me', '')
          .replaceAll('nearby', '')
          .replaceAll('nearest', '')
          .replaceAll('around here', '')
          .replaceAll('close by', '')
          .replaceAll(RegExp(r'[.?!]'), '')
          .trim();

      if (term.isNotEmpty) {
        return PlaceIntent(
          category: PlaceCategory.general,
          customSearchTerm: term,
          query: rawText,
        );
      }
    }

    return null;
  }
}
