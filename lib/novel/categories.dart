part of 'app.dart';

class _NovelCategories extends StatefulWidget {
  const _NovelCategories();
  @override
  State<_NovelCategories> createState() => _NovelCategoriesState();
}

class _NovelCategoriesState extends State<_NovelCategories> {
  CategoryFront? _front;
  int _tab = 1;
  String _dim = '0';
  bool _loading = true;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await NovelRuntime.ensureOnline();
      final front = await ApiClient.instance.categoryFront(tab: _tab);
      if (front.isEmpty) throw StateError('empty category');
      if (mounted && generation == _generation) setState(() => _front = front);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '分类加载失败，请联网重试');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('全部小说分类')),
    body: Column(
      children: [
        Wrap(
          spacing: 12,
          children: [
            for (final e in {1: '男生', 2: '女生', 4: '出版'}.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _tab == e.key,
                onSelected: (_) {
                  setState(() {
                    _tab = e.key;
                    _dim = '0';
                    _front = null;
                  });
                  _load();
                },
              ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) TextButton(onPressed: _load, child: Text(_error!)),
        if (_front != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                for (final d in _front!.dims)
                  ChoiceChip(
                    label: Text(d.name),
                    selected: _dim == d.value,
                    onSelected: (_) => setState(() => _dim = d.value),
                  ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final tile in _front?.tiles ?? <CategoryTile>[])
                  if (_dim == '0' || tile.dim == _dim)
                    ActionChip(
                      label: Text(tile.name),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => NovelSearch(initialQuery: tile.name),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
