package models

import (
	"time"

	"server-storage/internal/lib/goose"
)

// AdContent holds the polymorphic content fields for an Ad.
type AdContent struct {
	MP4URL      *string  `bson:"mp4Url,omitempty" json:"mp4Url,omitempty"`
	SkipSeconds *int     `bson:"skipSeconds,omitempty" json:"skipSeconds,omitempty"`
	Placement   *string  `bson:"placement,omitempty" json:"placement,omitempty"` // pre_roll, mid_roll, post_roll
	ImageURL    *string  `bson:"imageUrl,omitempty" json:"imageUrl,omitempty"`
	ShowOn      []string `bson:"showOn,omitempty" json:"showOn,omitempty"` // ready, end, pause
	WebsiteURL  *string  `bson:"websiteUrl,omitempty" json:"websiteUrl,omitempty"`
	Script      *string  `bson:"script,omitempty" json:"script,omitempty"`
}

// Ad represents an advertisement.
// Collection: "ads" | _id: String (UUID)
type Ad struct {
	ID        string     `bson:"_id" json:"id" goose:"required,default:uuid"`
	SpaceID   string     `bson:"spaceId" json:"spaceId" goose:"ref:workspaces,index"`
	CreatorID string     `bson:"creatorId" json:"creatorId" goose:"ref:user"`
	Name      string     `bson:"name" json:"name" goose:"required"`
	Type      string     `bson:"type" json:"type" goose:"required"` // video, image, script
	Status    string     `bson:"status" json:"status" goose:"default:active"`
	Content   *AdContent `bson:"content,omitempty" json:"content,omitempty"`
	CreatedAt time.Time  `bson:"createdAt" json:"createdAt" goose:"default:now"`
	UpdatedAt time.Time  `bson:"updatedAt" json:"updatedAt" goose:"default:now"`
}

// AdModel is the goose model for the "ads" collection.
var AdModel = goose.NewModel[Ad]("ads")
