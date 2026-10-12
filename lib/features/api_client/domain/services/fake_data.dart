import 'dart:math';

/// One `{{$random…}}` variable. Names follow Postman's dynamic variables
/// (which are based on faker.js), so imported Postman collections that use
/// them work unchanged.
class FakeVariable {
  const FakeVariable(this.name, this.category, this.description, this._make);

  /// Variable name including the leading `$`, e.g. `$randomEmail`.
  final String name;
  final String category;
  final String description;
  final String Function(FakeData f) _make;

  String generate(FakeData f) => _make(f);
}

/// Generates realistic-looking random values (English only). A new value is
/// produced on every call, so each request gets fresh data.
class FakeData {
  FakeData({Random? random, DateTime Function()? clock})
    : _r = random ?? Random.secure(),
      _clock = clock ?? DateTime.now;

  final Random _r;
  final DateTime Function() _clock;

  static final Map<String, FakeVariable> _byName = {
    for (final v in variables) v.name: v,
  };

  static FakeVariable? find(String name) => _byName[name];

  /// Categories in display order.
  static const categories = [
    'Names',
    'Internet',
    'Address',
    'Phone',
    'Company',
    'Finance',
    'Commerce',
    'Date',
    'Text',
    'Numbers & IDs',
  ];

  /// A fresh value for [name], or null when it is not a fake-data variable.
  String? generate(String name) => _byName[name]?.generate(this);

  // ---------------------------------------------------------------- helpers

  T _pick<T>(List<T> list) => list[_r.nextInt(list.length)];
  int _int(int min, int max) => min + _r.nextInt(max - min + 1);
  String _digits(int n) => List.generate(n, (_) => _r.nextInt(10)).join();
  String _chars(String alphabet, int n) =>
      List.generate(n, (_) => alphabet[_r.nextInt(alphabet.length)]).join();
  String _hex(int n) => _chars('0123456789abcdef', n);
  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  String _ascii(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  String get firstName => _pick(_firstNames);
  String get lastName => _pick(_lastNames);

  String _sentence(int words) =>
      '${_cap(List.generate(words, (_) => _pick(_lorem)).join(' '))}.';
  String _paragraph() =>
      List.generate(_int(3, 5), (_) => _sentence(_int(6, 12))).join(' ');

  String _date(Duration offset) => _clock().toUtc().add(offset).toIso8601String();
  Duration _seconds(int min, int max) => Duration(seconds: _int(min, max));

  // -------------------------------------------------------------- variables

  static final variables = <FakeVariable>[
    // Names
    FakeVariable(r'$randomFirstName', 'Names', 'First name', (f) => f.firstName),
    FakeVariable(r'$randomLastName', 'Names', 'Last name', (f) => f.lastName),
    FakeVariable(
      r'$randomFullName',
      'Names',
      'First and last name',
      (f) => '${f.firstName} ${f.lastName}',
    ),
    FakeVariable(
      r'$randomNamePrefix',
      'Names',
      'Name prefix (Mr., Dr.…)',
      (f) => f._pick(_prefixes),
    ),
    FakeVariable(
      r'$randomNameSuffix',
      'Names',
      'Name suffix (Jr., PhD…)',
      (f) => f._pick(_suffixes),
    ),
    FakeVariable(
      r'$randomJobTitle',
      'Names',
      'Job title',
      (f) =>
          '${f._pick(_jobDescriptors)} ${f._pick(_jobAreas)} ${f._pick(_jobTypes)}',
    ),
    FakeVariable(r'$randomJobArea', 'Names', 'Job area', (f) => f._pick(_jobAreas)),
    FakeVariable(r'$randomJobType', 'Names', 'Job type', (f) => f._pick(_jobTypes)),

    // Internet
    FakeVariable(
      r'$randomEmail',
      'Internet',
      'Email address',
      (f) =>
          '${f._ascii(f.firstName)}.${f._ascii(f.lastName)}${f._int(1, 99)}'
          '@${f._pick(_freeEmailDomains)}',
    ),
    FakeVariable(
      r'$randomExampleEmail',
      'Internet',
      'Email at an example.* domain',
      (f) =>
          '${f._ascii(f.firstName)}.${f._ascii(f.lastName)}'
          '@${f._pick(const ['example.com', 'example.net', 'example.org'])}',
    ),
    FakeVariable(
      r'$randomUserName',
      'Internet',
      'User name',
      (f) => '${f.firstName}.${f.lastName}${f._int(1, 99)}',
    ),
    FakeVariable(
      r'$randomPassword',
      'Internet',
      '15-character alphanumeric password',
      (f) => f._chars(_alphaNumeric, 15),
    ),
    FakeVariable(
      r'$randomUrl',
      'Internet',
      'URL',
      (f) => 'https://${f._pick(_lorem)}-${f._pick(_lorem)}.${f._pick(_tlds)}',
    ),
    FakeVariable(
      r'$randomDomainName',
      'Internet',
      'Domain name',
      (f) => '${f._pick(_lorem)}${f._pick(_lorem)}.${f._pick(_tlds)}',
    ),
    FakeVariable(r'$randomDomainWord', 'Internet', 'Domain word', (f) => f._pick(_lorem)),
    FakeVariable(r'$randomDomainSuffix', 'Internet', 'Domain suffix', (f) => f._pick(_tlds)),
    FakeVariable(
      r'$randomIP',
      'Internet',
      'IPv4 address',
      (f) => List.generate(4, (_) => f._int(1, 254)).join('.'),
    ),
    FakeVariable(
      r'$randomIPV6',
      'Internet',
      'IPv6 address',
      (f) => List.generate(8, (_) => f._hex(4)).join(':'),
    ),
    FakeVariable(
      r'$randomMACAddress',
      'Internet',
      'MAC address',
      (f) => List.generate(6, (_) => f._hex(2)).join(':'),
    ),
    FakeVariable(
      r'$randomUserAgent',
      'Internet',
      'Browser user agent',
      (f) => f._pick(_userAgents),
    ),
    FakeVariable(
      r'$randomProtocol',
      'Internet',
      'http or https',
      (f) => f._pick(const ['http', 'https']),
    ),
    FakeVariable(
      r'$randomSemver',
      'Internet',
      'Semantic version (1.2.3)',
      (f) => '${f._int(0, 9)}.${f._int(0, 20)}.${f._int(0, 30)}',
    ),
    FakeVariable(
      r'$randomLocale',
      'Internet',
      'Two-letter language code',
      (f) => f._pick(_locales),
    ),

    // Address
    FakeVariable(r'$randomCity', 'Address', 'City', (f) => f._pick(_cities)),
    FakeVariable(
      r'$randomStreetName',
      'Address',
      'Street name',
      (f) => '${f.lastName} ${f._pick(_streetSuffixes)}',
    ),
    FakeVariable(
      r'$randomStreetAddress',
      'Address',
      'Street address',
      (f) => '${f._int(1, 9999)} ${f.lastName} ${f._pick(_streetSuffixes)}',
    ),
    FakeVariable(
      r'$randomZipCode',
      'Address',
      'Five-digit ZIP code',
      (f) => f._digits(5),
    ),
    FakeVariable(
      r'$randomCountry',
      'Address',
      'Country',
      (f) => f._pick(_countries).$2,
    ),
    FakeVariable(
      r'$randomCountryCode',
      'Address',
      'Two-letter country code',
      (f) => f._pick(_countries).$1,
    ),
    FakeVariable(
      r'$randomLatitude',
      'Address',
      'Latitude',
      (f) => (f._r.nextDouble() * 180 - 90).toStringAsFixed(4),
    ),
    FakeVariable(
      r'$randomLongitude',
      'Address',
      'Longitude',
      (f) => (f._r.nextDouble() * 360 - 180).toStringAsFixed(4),
    ),

    // Phone
    FakeVariable(
      r'$randomPhoneNumber',
      'Phone',
      'Phone number',
      (f) => '${f._int(200, 989)}-${f._int(200, 989)}-${f._digits(4)}',
    ),
    FakeVariable(
      r'$randomPhoneNumberExt',
      'Phone',
      'Phone number with country code',
      (f) =>
          '${f._int(1, 99)}-${f._int(200, 989)}-${f._int(200, 989)}-${f._digits(4)}',
    ),

    // Company
    FakeVariable(
      r'$randomCompanyName',
      'Company',
      'Company name',
      (f) => switch (f._r.nextInt(3)) {
        0 => '${f.lastName} ${f._pick(_companySuffixes)}',
        1 => '${f.lastName}-${f.lastName}',
        _ => '${f.lastName}, ${f.lastName} and ${f.lastName}',
      },
    ),
    FakeVariable(
      r'$randomCompanySuffix',
      'Company',
      'Company suffix (Inc, LLC…)',
      (f) => f._pick(_companySuffixes),
    ),
    FakeVariable(
      r'$randomCatchPhrase',
      'Company',
      'Catch phrase',
      (f) =>
          '${f._cap(f._pick(_catchAdjectives))} ${f._pick(_catchDescriptors)} '
          '${f._pick(_catchNouns)}',
    ),
    FakeVariable(
      r'$randomBs',
      'Company',
      'Business buzzwords',
      (f) =>
          '${f._pick(_bsVerbs)} ${f._pick(_bsAdjectives)} ${f._pick(_bsNouns)}',
    ),

    // Finance
    FakeVariable(
      r'$randomBankAccount',
      'Finance',
      'Eight-digit bank account number',
      (f) => f._digits(8),
    ),
    FakeVariable(
      r'$randomBankAccountName',
      'Finance',
      'Bank account name',
      (f) => f._pick(_accountNames),
    ),
    FakeVariable(
      r'$randomBankAccountBic',
      'Finance',
      'BIC (SWIFT) code',
      (f) =>
          '${f._chars(_upper, 4)}${f._pick(_countries).$1}'
          '${f._chars(_upper, 2)}${f._chars(_upper, 3)}',
    ),
    FakeVariable(
      r'$randomCreditCardMask',
      'Finance',
      'Last four card digits',
      (f) => f._digits(4),
    ),
    FakeVariable(
      r'$randomCurrencyCode',
      'Finance',
      'Currency code (USD…)',
      (f) => f._pick(_currencies).$1,
    ),
    FakeVariable(
      r'$randomCurrencyName',
      'Finance',
      'Currency name',
      (f) => f._pick(_currencies).$2,
    ),
    FakeVariable(
      r'$randomCurrencySymbol',
      'Finance',
      'Currency symbol',
      (f) => f._pick(_currencies).$3,
    ),
    FakeVariable(
      r'$randomTransactionType',
      'Finance',
      'Transaction type',
      (f) => f._pick(const ['deposit', 'withdrawal', 'payment', 'invoice']),
    ),
    FakeVariable(
      r'$randomBitcoin',
      'Finance',
      'Bitcoin address',
      (f) => '${f._pick(const ['1', '3'])}${f._chars(_base58, f._int(25, 33))}',
    ),

    // Commerce
    FakeVariable(
      r'$randomPrice',
      'Commerce',
      'Price (e.g. 531.55)',
      (f) => (f._int(100, 100000) / 100).toStringAsFixed(2),
    ),
    FakeVariable(r'$randomProduct', 'Commerce', 'Product', (f) => f._pick(_products)),
    FakeVariable(
      r'$randomProductName',
      'Commerce',
      'Product name',
      (f) =>
          '${f._pick(_productAdjectives)} ${f._pick(_productMaterials)} '
          '${f._pick(_products)}',
    ),
    FakeVariable(
      r'$randomProductAdjective',
      'Commerce',
      'Product adjective',
      (f) => f._pick(_productAdjectives),
    ),
    FakeVariable(
      r'$randomProductMaterial',
      'Commerce',
      'Product material',
      (f) => f._pick(_productMaterials),
    ),
    FakeVariable(
      r'$randomDepartment',
      'Commerce',
      'Store department',
      (f) => f._pick(_departments),
    ),
    FakeVariable(r'$randomColor', 'Commerce', 'Color name', (f) => f._pick(_colors)),
    FakeVariable(
      r'$randomHexColor',
      'Commerce',
      'Hex color (#a1b2c3)',
      (f) => '#${f._hex(6)}',
    ),

    // Date
    FakeVariable(
      r'$randomDatePast',
      'Date',
      'ISO date in the past year',
      (f) => f._date(-f._seconds(60, 365 * 86400)),
    ),
    FakeVariable(
      r'$randomDateFuture',
      'Date',
      'ISO date in the next year',
      (f) => f._date(f._seconds(60, 365 * 86400)),
    ),
    FakeVariable(
      r'$randomDateRecent',
      'Date',
      'ISO date in the last day',
      (f) => f._date(-f._seconds(1, 86400)),
    ),
    FakeVariable(r'$randomWeekday', 'Date', 'Weekday', (f) => f._pick(_weekdays)),
    FakeVariable(r'$randomMonth', 'Date', 'Month', (f) => f._pick(_months)),

    // Text
    FakeVariable(r'$randomWord', 'Text', 'Single word', (f) => f._pick(_lorem)),
    FakeVariable(
      r'$randomWords',
      'Text',
      'A few words',
      (f) => List.generate(f._int(2, 4), (_) => f._pick(_lorem)).join(' '),
    ),
    FakeVariable(
      r'$randomLoremWord',
      'Text',
      'Lorem ipsum word',
      (f) => f._pick(_lorem),
    ),
    FakeVariable(
      r'$randomLoremSentence',
      'Text',
      'Lorem ipsum sentence',
      (f) => f._sentence(f._int(6, 12)),
    ),
    FakeVariable(
      r'$randomLoremParagraph',
      'Text',
      'Lorem ipsum paragraph',
      (f) => f._paragraph(),
    ),
    FakeVariable(
      r'$randomLoremSlug',
      'Text',
      'URL slug (three words)',
      (f) => List.generate(3, (_) => f._pick(_lorem)).join('-'),
    ),

    // Numbers & IDs
    FakeVariable(
      r'$randomUUID',
      'Numbers & IDs',
      'Random UUID v4',
      (f) => f._uuid(),
    ),
    FakeVariable(
      r'$randomBoolean',
      'Numbers & IDs',
      'true or false',
      (f) => f._r.nextBool().toString(),
    ),
    FakeVariable(
      r'$randomAlphaNumeric',
      'Numbers & IDs',
      'Single letter or digit',
      (f) => f._chars(_alphaNumeric, 1),
    ),
    FakeVariable(
      r'$randomFileName',
      'Numbers & IDs',
      'File name',
      (f) => '${f._pick(_lorem)}_${f._pick(_lorem)}.${f._pick(_fileExtensions)}',
    ),
    FakeVariable(
      r'$randomFileExt',
      'Numbers & IDs',
      'File extension',
      (f) => f._pick(_fileExtensions),
    ),
    FakeVariable(
      r'$randomMimeType',
      'Numbers & IDs',
      'MIME type',
      (f) => f._pick(_mimeTypes),
    ),
  ];

  String _uuid() {
    final h = _hex(32).split('');
    h[12] = '4';
    h[16] = '89ab'[_r.nextInt(4)];
    final s = h.join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-'
        '${s.substring(16, 20)}-${s.substring(20)}';
  }
}

// ------------------------------------------------------------------ word lists

const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const _alphaNumeric =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const _base58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

const _firstNames = [
  'Olivia', 'Liam', 'Emma', 'Noah', 'Ava', 'Elijah', 'Sophia', 'James',
  'Isabella', 'Lucas', 'Mia', 'Mason', 'Amelia', 'Ethan', 'Harper', 'Logan',
  'Evelyn', 'Aiden', 'Abigail', 'Jackson', 'Emily', 'Sebastian', 'Ella',
  'Mateo', 'Scarlett', 'Henry', 'Grace', 'Owen', 'Chloe', 'Leo', 'Zoe', 'Ezra',
  'Nora', 'Jaylen', 'Riley', 'Kai', 'Layla', 'Darby', 'Aria', 'Rowan',
];

const _lastNames = [
  'Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller',
  'Davis', 'Rodriguez', 'Martinez', 'Hernandez', 'Lopez', 'Wilson', 'Anderson',
  'Thomas', 'Taylor', 'Moore', 'Jackson', 'Martin', 'Lee', 'Thompson', 'White',
  'Harris', 'Clark', 'Lewis', 'Robinson', 'Walker', 'Young', 'Allen', 'King',
  'Wright', 'Scott', 'Hudson', 'Kub', 'Schmidt', 'Okafor', 'Nguyen', 'Patel',
  'Kowalski', 'Fischer',
];

const _prefixes = ['Mr.', 'Mrs.', 'Ms.', 'Miss', 'Dr.'];
const _suffixes = ['Jr.', 'Sr.', 'II', 'III', 'IV', 'V', 'MD', 'DDS', 'PhD'];

const _jobDescriptors = [
  'Lead', 'Senior', 'Direct', 'Corporate', 'Dynamic', 'Future', 'Product',
  'National', 'Regional', 'District', 'Central', 'Global', 'Customer',
  'Investor', 'International', 'Legacy', 'Forward', 'Internal', 'Chief',
  'Principal',
];
const _jobAreas = [
  'Solutions', 'Program', 'Brand', 'Security', 'Research', 'Marketing',
  'Directives', 'Implementation', 'Integration', 'Functionality', 'Response',
  'Paradigm', 'Tactics', 'Identity', 'Markets', 'Group', 'Division',
  'Applications', 'Optimization', 'Operations', 'Infrastructure', 'Intranet',
  'Communications', 'Web', 'Quality', 'Assurance', 'Mobility', 'Accounts',
  'Data', 'Creative', 'Configuration', 'Interactions', 'Factors', 'Usability',
  'Metrics',
];
const _jobTypes = [
  'Supervisor', 'Associate', 'Executive', 'Liaison', 'Officer', 'Manager',
  'Engineer', 'Specialist', 'Director', 'Coordinator', 'Administrator',
  'Architect', 'Analyst', 'Designer', 'Planner', 'Orchestrator', 'Technician',
  'Developer', 'Producer', 'Consultant', 'Assistant', 'Facilitator', 'Agent',
  'Representative', 'Strategist',
];

const _freeEmailDomains = ['gmail.com', 'yahoo.com', 'hotmail.com', 'outlook.com'];
const _tlds = ['com', 'net', 'org', 'io', 'info', 'biz', 'name', 'dev'];
const _locales = [
  'en', 'de', 'fr', 'es', 'it', 'pt', 'nl', 'sv', 'pl', 'ru', 'ja', 'ko', 'zh',
  'ar', 'hi', 'bn', 'tr', 'vi',
];
const _userAgents = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15',
  'Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0',
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1',
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
];

const _cities = [
  'Springfield', 'Riverside', 'Fairview', 'Madison', 'Georgetown', 'Clinton',
  'Franklin', 'Greenville', 'Bristol', 'Salem', 'Ashland', 'Oxford', 'Dover',
  'Milton', 'Newport', 'Burlington', 'Kingston', 'Arlington', 'Lakewood',
  'Hudson', 'Portland', 'Auburn', 'Jackson', 'Marion', 'Lebanon',
];
const _streetSuffixes = [
  'Street', 'Avenue', 'Road', 'Lane', 'Drive', 'Court', 'Place', 'Way',
  'Boulevard', 'Terrace', 'Parkway', 'Circle',
];
const _countries = [
  ('US', 'United States'), ('GB', 'United Kingdom'), ('CA', 'Canada'),
  ('AU', 'Australia'), ('DE', 'Germany'), ('FR', 'France'), ('ES', 'Spain'),
  ('IT', 'Italy'), ('NL', 'Netherlands'), ('SE', 'Sweden'), ('NO', 'Norway'),
  ('JP', 'Japan'), ('KR', 'South Korea'), ('IN', 'India'), ('BD', 'Bangladesh'),
  ('BR', 'Brazil'), ('MX', 'Mexico'), ('ZA', 'South Africa'), ('NG', 'Nigeria'),
  ('SG', 'Singapore'), ('NZ', 'New Zealand'), ('IE', 'Ireland'),
];

const _companySuffixes = ['Inc', 'LLC', 'Group', 'and Sons', 'Ltd', 'Co'];
const _catchAdjectives = [
  'adaptive', 'advanced', 'automated', 'balanced', 'centralized', 'compatible',
  'configurable', 'cross-platform', 'customizable', 'decentralized',
  'digitized', 'distributed', 'enhanced', 'ergonomic', 'exclusive', 'expanded',
  'focused', 'innovative', 'integrated', 'intuitive', 'managed', 'optimized',
  'proactive', 'robust', 'seamless', 'secured', 'streamlined', 'synergized',
  'universal', 'user-friendly', 'versatile', 'virtual',
];
const _catchDescriptors = [
  '24/7', 'asymmetric', 'bifurcated', 'contextually-based', 'dedicated',
  'dynamic', 'fault-tolerant', 'global', 'heuristic', 'high-level',
  'interactive', 'local', 'logistical', 'mission-critical', 'modular',
  'multimedia', 'next generation', 'real-time', 'scalable', 'stable',
  'systematic', 'tangible', 'value-added', 'zero tolerance',
];
const _catchNouns = [
  'ability', 'access', 'adapter', 'algorithm', 'alliance', 'analyzer',
  'application', 'architecture', 'array', 'capacity', 'challenge', 'circuit',
  'database', 'emulation', 'encoding', 'firmware', 'framework', 'groupware',
  'hierarchy', 'infrastructure', 'interface', 'knowledge base', 'matrix',
  'methodology', 'middleware', 'model', 'moratorium', 'paradigm', 'platform',
  'portal', 'protocol', 'solution', 'strategy', 'toolset', 'workforce',
];
const _bsVerbs = [
  'implement', 'utilize', 'integrate', 'streamline', 'optimize', 'evolve',
  'transform', 'embrace', 'enable', 'orchestrate', 'leverage', 'reinvent',
  'aggregate', 'architect', 'enhance', 'incentivize', 'morph', 'empower',
  'scale', 'disintermediate', 'synergize', 'strategize', 'deploy', 'brand',
  'grow', 'target', 'syndicate', 'deliver', 'expedite', 'monetize',
];
const _bsAdjectives = [
  'clicks-and-mortar', 'value-added', 'vertical', 'proactive', 'robust',
  'revolutionary', 'scalable', 'leading-edge', 'innovative', 'intuitive',
  'strategic', 'e-business', 'mission-critical', 'sticky', 'one-to-one',
  '24/7', 'end-to-end', 'global', 'B2B', 'B2C', 'granular', 'frictionless',
  'virtual', 'viral', 'dynamic', 'best-of-breed', 'cross-platform',
  'seamless', 'real-time', 'impactful',
];
const _bsNouns = [
  'synergies', 'paradigms', 'markets', 'partnerships', 'infrastructures',
  'platforms', 'initiatives', 'channels', 'eyeballs', 'communities',
  'solutions', 'action-items', 'portals', 'niches', 'technologies', 'content',
  'supply-chains', 'convergence', 'relationships', 'architectures',
  'interfaces', 'e-markets', 'e-commerce', 'systems', 'bandwidth', 'models',
  'mindshare', 'deliverables', 'users', 'schemas', 'networks', 'metrics',
];

const _accountNames = [
  'Checking Account', 'Savings Account', 'Money Market Account',
  'Investment Account', 'Home Loan Account', 'Credit Card Account',
  'Auto Loan Account', 'Personal Loan Account',
];
const _currencies = [
  ('USD', 'US Dollar', r'$'), ('EUR', 'Euro', '€'),
  ('GBP', 'Pound Sterling', '£'), ('JPY', 'Yen', '¥'),
  ('INR', 'Indian Rupee', '₹'), ('BDT', 'Taka', '৳'),
  ('CAD', 'Canadian Dollar', r'$'), ('AUD', 'Australian Dollar', r'$'),
  ('CHF', 'Swiss Franc', 'CHF'), ('CNY', 'Yuan Renminbi', '¥'),
  ('KRW', 'Won', '₩'), ('BRL', 'Brazilian Real', r'R$'),
];

const _products = [
  'Chair', 'Car', 'Computer', 'Keyboard', 'Mouse', 'Bike', 'Ball', 'Gloves',
  'Pants', 'Shirt', 'Table', 'Shoes', 'Hat', 'Towels', 'Soap', 'Tuna',
  'Chicken', 'Fish', 'Cheese', 'Bacon', 'Pizza', 'Salad', 'Sausages', 'Chips',
];
const _productAdjectives = [
  'Small', 'Ergonomic', 'Rustic', 'Intelligent', 'Gorgeous', 'Incredible',
  'Fantastic', 'Practical', 'Sleek', 'Awesome', 'Generic', 'Handcrafted',
  'Handmade', 'Licensed', 'Refined', 'Unbranded', 'Tasty',
];
const _productMaterials = [
  'Steel', 'Wooden', 'Concrete', 'Plastic', 'Cotton', 'Granite', 'Rubber',
  'Metal', 'Soft', 'Fresh', 'Frozen', 'Bronze', 'Silk',
];
const _departments = [
  'Books', 'Movies', 'Music', 'Games', 'Electronics', 'Computers', 'Home',
  'Garden', 'Tools', 'Grocery', 'Health', 'Beauty', 'Toys', 'Kids', 'Baby',
  'Clothing', 'Shoes', 'Jewelery', 'Sports', 'Outdoors', 'Automotive',
  'Industrial',
];
const _colors = [
  'red', 'green', 'blue', 'yellow', 'purple', 'orange', 'pink', 'teal',
  'cyan', 'magenta', 'lime', 'maroon', 'navy', 'olive', 'silver', 'gold',
  'indigo', 'violet', 'turquoise', 'salmon', 'plum', 'orchid', 'tan', 'white',
  'black',
];

const _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

const _lorem = [
  'lorem', 'ipsum', 'dolor', 'sit', 'amet', 'consectetur', 'adipiscing',
  'elit', 'sed', 'do', 'eiusmod', 'tempor', 'incididunt', 'labore', 'dolore',
  'magna', 'aliqua', 'enim', 'minim', 'veniam', 'quis', 'nostrud',
  'exercitation', 'ullamco', 'laboris', 'nisi', 'aliquip', 'commodo',
  'consequat', 'duis', 'aute', 'irure', 'reprehenderit', 'voluptate', 'velit',
  'esse', 'cillum', 'fugiat', 'nulla', 'pariatur', 'excepteur', 'sint',
  'occaecat', 'cupidatat', 'proident', 'sunt', 'culpa', 'officia', 'deserunt',
  'mollit', 'anim', 'laborum',
];

const _fileExtensions = [
  'txt', 'pdf', 'png', 'jpg', 'gif', 'csv', 'json', 'xml', 'zip', 'mp3',
  'mp4', 'docx', 'xlsx',
];
const _mimeTypes = [
  'text/plain', 'text/html', 'text/csv', 'application/json',
  'application/xml', 'application/pdf', 'application/zip', 'image/png',
  'image/jpeg', 'image/gif', 'audio/mpeg', 'video/mp4',
];
