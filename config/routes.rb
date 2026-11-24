Rails.application.routes.draw do
  root "playground#show"
  get "up" => "rails/health#show"
  get "search.json" => "capture#show", format: false, defaults: { format: :json }
  get "playground/search" => "capture#show", defaults: { format: :json }
  get "example.json" => "capture#example", format: false, defaults: { format: :json }
  post "internal/capture" => "capture#capture", defaults: { format: :json }
  get "internal/renderer-health" => "capture#health"
end
