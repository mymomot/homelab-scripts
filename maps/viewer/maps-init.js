const map = new maplibregl.Map({
  container: 'map',
  style: '/style.json',
  center: [2.3522, 48.8566],   // Paris
  zoom: 5,
  maxZoom: 14
});
map.addControl(new maplibregl.NavigationControl());
map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }));
