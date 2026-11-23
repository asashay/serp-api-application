Rails.application.routes.draw do
  root "playground#show"
  get "up" => "rails/health#show"
  get "search.json" => "search#show", format: false, defaults: { format: :json }
  get "playground/search" => "search#show", defaults: { format: :json, preview: true }
  get "example.json" => "search#example", format: false, defaults: { format: :json }
  post "internal/search" => "search#parse", defaults: { format: :json }
end
