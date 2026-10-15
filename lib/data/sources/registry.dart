// OWNER: integrator. The one place sources are registered, highest priority
// first (priority decides which copy wins when the same title is found on
// several sources). Catalog reads this list.
import '../source.dart';
import 'dramabite_source.dart';
import 'flickreels_source.dart';
import 'goodshort_source.dart';
import 'idrama_source.dart';
import 'microdrama_source.dart';
import 'reelfren_source.dart';
import 'shortmax_source.dart';
import 'shortwave_source.dart';
import 'stardust_source.dart';
import 'starshort_source.dart';

List<DramaSource> buildSources() => [
      // Direct, no Cloudflare.
      ShortMaxSource(),
      ReelFrenSource(),
      IDramaSource(),
      FlickReelsSource(),
      // Cloudflare-protected: need a one-time user check (WebSession).
      StardustSource(),
      StarShortSource(),
      DramaBiteSource(),
      MicroDramaSource(),
      ShortWaveSource(),
      // Slow/flaky backend: lowest priority so duplicates prefer other copies.
      GoodShortSource(),
    ];
